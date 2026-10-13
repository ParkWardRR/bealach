import BealachCore
import BealachFormat
import Foundation
import Testing

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // BealachCoreTests/
    .deletingLastPathComponent() // Tests/
    .deletingLastPathComponent() // ios/
    .deletingLastPathComponent() // Bealach/

private let interopDir = repoRoot
    .appendingPathComponent("firmware/test/host/build/interop-out")

private func loadInteropEnv() throws -> (deviceKey: Data, rootKey: Data, keyVersion: UInt32, bundles: [String]) {
    let envPath = interopDir.appendingPathComponent("interop.env")
    let contents = try String(contentsOf: envPath, encoding: .utf8)
    var deviceKey: Data?
    var rootKey: Data?
    var keyVersion: UInt32 = 0
    var bundles: [String] = []

    for line in contents.components(separatedBy: "\n") {
        let parts = line.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { continue }
        let key = String(parts[0])
        let value = String(parts[1]).trimmingCharacters(in: .init(charactersIn: "\""))
        switch key {
        case "DEVICE_KEY": deviceKey = Data(hexString: value)
        case "ROOT_KEY": rootKey = Data(hexString: value)
        case "KEY_VERSION": keyVersion = UInt32(value) ?? 0
        case "BUNDLES": bundles = value.split(separator: " ").map(String.init)
        default: break
        }
    }

    guard let dk = deviceKey, let rk = rootKey else {
        throw InteropError.missingKeys
    }
    return (dk, rk, keyVersion, bundles)
}

private enum InteropError: Error {
    case missingKeys
    case missingFile(String)
}

@Suite(.serialized) struct InteropVerifierTests {
    let verifier = BundleVerifier()

    private func bundleDir(_ bundleID: String) -> URL {
        interopDir
            .appendingPathComponent("card/cairn/bundles")
            .appendingPathComponent(bundleID)
    }

    private func interopAvailable() -> Bool {
        FileManager.default.fileExists(
            atPath: interopDir.appendingPathComponent("interop.env").path
        )
    }

    // MARK: - Small bundle (single segment, no rotation)

    @Test func smallBundleManifestSignatureVerifies() throws {
        try #require(interopAvailable(), "Run `make interop-writer` in firmware/test/host first")
        let env = try loadInteropEnv()
        let bundleID = try #require(env.bundles.last)

        let manifest = try Data(contentsOf: bundleDir(bundleID).appendingPathComponent("manifest.cbor"))
        let signature = try Data(contentsOf: bundleDir(bundleID).appendingPathComponent("manifest.sig"))

        let result = try verifier.verifyManifestSignature(
            manifestBytes: manifest,
            signature: signature,
            devicePublicKey: env.deviceKey
        )

        #expect(result.bundleID.count == 16)
        #expect(result.contentRoot.count == 32)
        #expect(result.manifestHash.count == 32)
        #expect(result.memberCount >= 2, "at least seg + journal")
        #expect(result.totalBytes > 0)
    }

    @Test func smallBundleContentRootVerifies() throws {
        try #require(interopAvailable())
        let env = try loadInteropEnv()
        let bundleID = try #require(env.bundles.last)

        let manifest = try Data(contentsOf: bundleDir(bundleID).appendingPathComponent("manifest.cbor"))
        try verifier.verifyContentRoot(manifestBytes: manifest)
    }

    @Test func smallBundleStructuralScanPasses() throws {
        try #require(interopAvailable())
        let bundleID = try #require(try loadInteropEnv().bundles.last)

        let seg = try Data(contentsOf: bundleDir(bundleID).appendingPathComponent("seg-00000000.seg"))
        let result = try scanLock.withLock { try verifier.structuralScan(segmentData: seg) }

        #expect(result.frames > 0, "segment should contain valid frames")
        #expect(result.stop == BEALACH_STOP_EOF, "should reach end of segment cleanly")
    }

    @Test func smallBundleKeyedScanPasses() throws {
        try #require(interopAvailable())
        let env = try loadInteropEnv()
        let bundleID = try #require(env.bundles.last)

        let seg = try Data(contentsOf: bundleDir(bundleID).appendingPathComponent("seg-00000000.seg"))
        let result = try scanLock.withLock { try verifier.keyedScan(segmentData: seg, rootKey: env.rootKey) }

        #expect(result.frames > 0)
        #expect(result.stop == BEALACH_STOP_EOF)
    }

    @Test func smallBundleJournalScanPasses() throws {
        try #require(interopAvailable())
        let env = try loadInteropEnv()
        let bundleID = try #require(env.bundles.last)

        let journal = try Data(contentsOf: bundleDir(bundleID).appendingPathComponent("journal.seg"))
        let result = try scanLock.withLock { try verifier.keyedScan(segmentData: journal, rootKey: env.rootKey) }

        #expect(result.frames > 0)
        #expect(result.stop == BEALACH_STOP_EOF)
    }

    // MARK: - Large bundle (multi-segment, rotation)

    @Test func largeBundleManifestSignatureVerifies() throws {
        try #require(interopAvailable())
        let env = try loadInteropEnv()
        let bundleID = try #require(env.bundles.first)

        let manifest = try Data(contentsOf: bundleDir(bundleID).appendingPathComponent("manifest.cbor"))
        let signature = try Data(contentsOf: bundleDir(bundleID).appendingPathComponent("manifest.sig"))

        let result = try verifier.verifyManifestSignature(
            manifestBytes: manifest,
            signature: signature,
            devicePublicKey: env.deviceKey
        )

        #expect(result.memberCount >= 3, "rotated bundle has >=2 capture segments + journal")
        #expect(result.totalBytes > 100_000, "large bundle should have substantial data")
    }

    @Test func largeBundleContentRootVerifies() throws {
        try #require(interopAvailable())
        let env = try loadInteropEnv()
        let bundleID = try #require(env.bundles.first)

        let manifest = try Data(contentsOf: bundleDir(bundleID).appendingPathComponent("manifest.cbor"))
        try verifier.verifyContentRoot(manifestBytes: manifest)
    }

    @Test func largeBundleAllSegmentsStructuralScan() throws {
        try #require(interopAvailable())
        let bundleID = try #require(try loadInteropEnv().bundles.first)
        let dir = bundleDir(bundleID)

        let segFiles = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("seg-") && $0.hasSuffix(".seg") }
            .sorted()

        #expect(segFiles.count >= 2, "large bundle should have rotated segments")

        var chainState = bealach_scan_state_t(expected_seq: 0, expected_prev: 0)
        for segFile in segFiles {
            let seg = try Data(contentsOf: dir.appendingPathComponent(segFile))

            let result: bealach_scan_result_t = try scanLock.withLock {
                var r = bealach_scan_result_t()
                let rc = seg.withUnsafeBytes { ptr in
                    bealach_scan_segment(
                        ptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        seg.count, chainState, nil, &r
                    )
                }
                guard rc == BEALACH_OK else {
                    throw VerificationFailure.structuralScanFailed(reason: "\(segFile)")
                }
                return r
            }
            #expect(result.frames > 0, "\(segFile) should have valid frames")
            #expect(result.stop == BEALACH_STOP_EOF, "\(segFile) should end cleanly")
            chainState = result.next
        }
    }

    @Test func largeBundleAllSegmentsKeyedScan() throws {
        try #require(interopAvailable())
        let env = try loadInteropEnv()
        let bundleID = try #require(env.bundles.first)
        let dir = bundleDir(bundleID)

        let segFiles = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("seg-") && $0.hasSuffix(".seg") }
            .sorted()

        var totalFrames = 0
        var chainState = bealach_scan_state_t(expected_seq: 0, expected_prev: 0)
        for segFile in segFiles {
            let seg = try Data(contentsOf: dir.appendingPathComponent(segFile))
            let result = try scanLock.withLock {
                try verifier.keyedScan(segmentData: seg, rootKey: env.rootKey, state: chainState)
            }
            #expect(result.frames > 0, "\(segFile) keyed scan")
            #expect(result.stop == BEALACH_STOP_EOF)
            totalFrames += result.frames
            chainState = result.next
        }
        #expect(totalFrames > 100, "large bundle should have many frames across segments")
    }

    @Test func largeBundleJournalKeyedScan() throws {
        try #require(interopAvailable())
        let env = try loadInteropEnv()
        let bundleID = try #require(env.bundles.first)

        let journal = try Data(contentsOf: bundleDir(bundleID).appendingPathComponent("journal.seg"))
        let result = try scanLock.withLock {
            try verifier.keyedScan(segmentData: journal, rootKey: env.rootKey)
        }

        #expect(result.frames > 0)
        #expect(result.stop == BEALACH_STOP_EOF)
    }

    // MARK: - Cross-implementation agreement

    @Test func wrongKeyRejectsInteropBundle() throws {
        try #require(interopAvailable())
        let env = try loadInteropEnv()
        let bundleID = try #require(env.bundles.last)

        let manifest = try Data(contentsOf: bundleDir(bundleID).appendingPathComponent("manifest.cbor"))
        let signature = try Data(contentsOf: bundleDir(bundleID).appendingPathComponent("manifest.sig"))

        let wrongKey = Data(repeating: 0xAA, count: 32)
        #expect(throws: VerificationFailure.self) {
            try verifier.verifyManifestSignature(
                manifestBytes: manifest,
                signature: signature,
                devicePublicKey: wrongKey
            )
        }
    }

    @Test func wrongRootKeyRejectsKeyedScan() throws {
        try #require(interopAvailable())
        let bundleID = try #require(try loadInteropEnv().bundles.last)

        let seg = try Data(contentsOf: bundleDir(bundleID).appendingPathComponent("seg-00000000.seg"))
        let wrongRoot = Data(repeating: 0xBB, count: 32)

        try scanLock.withLock {
            #expect(throws: VerificationFailure.self) {
                try verifier.keyedScan(segmentData: seg, rootKey: wrongRoot)
            }
        }
    }

    @Test func bothBundlesHaveDifferentCounters() throws {
        try #require(interopAvailable())
        let env = try loadInteropEnv()
        #expect(env.bundles.count == 2, "interop writer produces exactly two bundles")

        var results: [VerificationResult] = []
        for bundleID in env.bundles {
            let manifest = try Data(contentsOf: bundleDir(bundleID).appendingPathComponent("manifest.cbor"))
            let signature = try Data(contentsOf: bundleDir(bundleID).appendingPathComponent("manifest.sig"))
            let result = try verifier.verifyManifestSignature(
                manifestBytes: manifest, signature: signature, devicePublicKey: env.deviceKey
            )
            results.append(result)
        }

        #expect(results[0].bundleID != results[1].bundleID, "different bundle IDs")
        #expect(results[0].contentRoot != results[1].contentRoot, "different content roots")
    }
}
