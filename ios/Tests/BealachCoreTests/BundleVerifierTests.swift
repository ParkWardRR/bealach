import BealachCore
import BealachFormat
import Foundation
import Testing

private let vectorsRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // BealachCoreTests/
    .deletingLastPathComponent() // Tests/
    .deletingLastPathComponent() // ios/
    .deletingLastPathComponent() // Bealach/
    .appendingPathComponent("contracts/format/v3/vectors")

private let devicePublicKey = Data(hexString: "f876e06990f013620b0c41bb19cb6acb367d615cb52c3d8980a57582925a4e13")!
private let rootKey = Data(hexString: "7b1a2c5cc080bc43df4922975a48987d92e3209ba6a4bb8853a23651ad9b3821")!

extension Data {
    init?(hexString: String) {
        let hex = hexString.filter { $0.isHexDigit }
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

@Suite(.serialized) struct BundleVerifierTests {
    let verifier = BundleVerifier()

    // MARK: - Manifest Signature

    @Test func validManifestSignature() throws {
        let dir = vectorsRoot.appendingPathComponent("manifest-members-match")
        let manifestBytes = try Data(contentsOf: dir.appendingPathComponent("manifest.cbor"))
        let signature = try Data(contentsOf: dir.appendingPathComponent("manifest.sig"))

        let result = try verifier.verifyManifestSignature(
            manifestBytes: manifestBytes,
            signature: signature,
            devicePublicKey: devicePublicKey
        )

        #expect(result.bundleID.count == 16)
        #expect(result.contentRoot.hexString == "1da40231cc5be5532621a4997057f9d5846a109fa312de46c6f3b57420a803fd")
        #expect(result.manifestHash.hexString == "c8b5565f15b7e799dea0289d29d8371c452081b4b979e539c6b84aedfa26801a")
        #expect(result.memberCount > 0)
    }

    @Test func badSignatureRejected() throws {
        let dir = vectorsRoot.appendingPathComponent("manifest-bad-signature")
        let manifestBytes = try Data(contentsOf: dir.appendingPathComponent("manifest.cbor"))
        let signature = try Data(contentsOf: dir.appendingPathComponent("manifest.sig"))

        #expect(throws: VerificationFailure.manifestSignatureInvalid) {
            try verifier.verifyManifestSignature(
                manifestBytes: manifestBytes,
                signature: signature,
                devicePublicKey: devicePublicKey
            )
        }
    }

    @Test func wrongKeyRejected() throws {
        let dir = vectorsRoot.appendingPathComponent("manifest-members-match")
        let manifestBytes = try Data(contentsOf: dir.appendingPathComponent("manifest.cbor"))
        let signature = try Data(contentsOf: dir.appendingPathComponent("manifest.sig"))
        let wrongKey = Data(repeating: 0xAA, count: 32)

        #expect(throws: VerificationFailure.manifestSignatureInvalid) {
            try verifier.verifyManifestSignature(
                manifestBytes: manifestBytes,
                signature: signature,
                devicePublicKey: wrongKey
            )
        }
    }

    @Test func shortSignatureRejected() {
        let manifestBytes = Data(repeating: 0, count: 100)
        let shortSig = Data(repeating: 0, count: 32)

        #expect(throws: VerificationFailure.manifestSignatureInvalid) {
            try verifier.verifyManifestSignature(
                manifestBytes: manifestBytes,
                signature: shortSig,
                devicePublicKey: devicePublicKey
            )
        }
    }

    // MARK: - Content Root

    @Test func validContentRoot() throws {
        let dir = vectorsRoot.appendingPathComponent("manifest-members-match")
        let manifestBytes = try Data(contentsOf: dir.appendingPathComponent("manifest.cbor"))
        try verifier.verifyContentRoot(manifestBytes: manifestBytes)
    }

    // MARK: - Chunk Digest

    @Test func chunkDigestMatch() throws {
        let chunk = Data("hello world".utf8)
        var expected = Data(count: 32)
        chunk.withUnsafeBytes { ptr in
            expected.withUnsafeMutableBytes { out in
                bealach_sha256(
                    ptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    chunk.count,
                    out.baseAddress?.assumingMemoryBound(to: UInt8.self)
                )
            }
        }
        try verifier.verifyChunkDigest(chunkData: chunk, expectedDigest: expected, index: 0)
    }

    @Test func chunkDigestMismatch() {
        let chunk = Data("hello world".utf8)
        let wrong = Data(repeating: 0xFF, count: 32)

        #expect(throws: VerificationFailure.chunkDigestMismatch(index: 3)) {
            try verifier.verifyChunkDigest(chunkData: chunk, expectedDigest: wrong, index: 3)
        }
    }

    // MARK: - Structural Scan

    @Test func structuralScanValidSegment() throws {
        let dir = vectorsRoot.appendingPathComponent("valid-minimal")
        let segmentData = try Data(contentsOf: dir.appendingPathComponent("segment.bin"))
        let result = try verifier.structuralScan(segmentData: segmentData)
        #expect(result.frames == 10)
        #expect(result.stop == BEALACH_STOP_EOF)
        #expect(result.discarded_tail_bytes == 0)
        #expect(result.first_seq == 0)
        #expect(result.last_seq == 9)
    }

    @Test func structuralScanTornTail() throws {
        let dir = vectorsRoot.appendingPathComponent("torn-tail-mid-frame")
        let segmentData = try Data(contentsOf: dir.appendingPathComponent("segment.bin"))
        let result = try verifier.structuralScan(segmentData: segmentData)
        #expect(result.stop == BEALACH_STOP_TORN_TAIL)
        #expect(result.discarded_tail_bytes > 0)
    }

    // MARK: - Keyed Scan (AEAD)

    @Test func keyedScanValidSegment() throws {
        let dir = vectorsRoot.appendingPathComponent("valid-minimal")
        let segmentData = try Data(contentsOf: dir.appendingPathComponent("segment.bin"))
        let result = try verifier.keyedScan(segmentData: segmentData, rootKey: rootKey)
        #expect(result.frames == 10)
        #expect(result.keyed)
        #expect(result.stop == BEALACH_STOP_EOF)
    }

    @Test func keyedScanWrongKey() throws {
        let dir = vectorsRoot.appendingPathComponent("valid-minimal")
        let segmentData = try Data(contentsOf: dir.appendingPathComponent("segment.bin"))
        let wrongKey = Data(repeating: 0xBB, count: 32)

        #expect {
            try verifier.keyedScan(segmentData: segmentData, rootKey: wrongKey)
        } throws: { error in
            guard let failure = error as? VerificationFailure else { return false }
            if case .aeadAuthenticationFailed = failure { return true }
            return false
        }
    }

    @Test func keyedScanShortKeyRejected() {
        let segmentData = Data(repeating: 0, count: 128)
        let shortKey = Data(repeating: 0, count: 16)

        #expect(throws: VerificationFailure.noRootKey) {
            try verifier.keyedScan(segmentData: segmentData, rootKey: shortKey)
        }
    }

    // MARK: - Chain Break

    @Test func structuralScanChainBreak() throws {
        let dir = vectorsRoot.appendingPathComponent("chain-break-spliced")
        let segmentData = try Data(contentsOf: dir.appendingPathComponent("segment.bin"))
        let result = try verifier.structuralScan(segmentData: segmentData)
        #expect(result.stop == BEALACH_STOP_CHAIN_BREAK)
    }

    // MARK: - Bad CRC

    @Test func structuralScanBadFrameCRC() throws {
        let dir = vectorsRoot.appendingPathComponent("bad-frame-crc")
        let segmentData = try Data(contentsOf: dir.appendingPathComponent("segment.bin"))
        let result = try verifier.structuralScan(segmentData: segmentData)
        #expect(result.stop == BEALACH_STOP_CORRUPT_FRAME)
    }
}
