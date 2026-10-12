import BealachCore
import BealachFormat
import Foundation
import GRDB
import os

public final class VerifyingBundleSink: BundleSink, @unchecked Sendable {
    private static let log = Logger(subsystem: "app.bealach", category: "verifying-sink")

    private let devicePublicKey: Data
    private let rootKey: Data
    private let ownerSeed: Data
    private let ownerPublicKey: Data
    private let bundleDir: URL
    private let db: BealachDatabase
    private let verifier = BundleVerifier()

    public init(
        devicePublicKey: Data,
        rootKey: Data,
        ownerSeed: Data,
        ownerPublicKey: Data,
        bundleDir: URL,
        db: BealachDatabase
    ) {
        self.devicePublicKey = devicePublicKey
        self.rootKey = rootKey
        self.ownerSeed = ownerSeed
        self.ownerPublicKey = ownerPublicKey
        self.bundleDir = bundleDir
        self.db = db
    }

    public func importBundle(
        manifest: Data,
        signature: String,
        readChunk: @Sendable (Int64, Int64) async throws -> Data,
        onChunk: @Sendable (Int, Int, Int64) -> Void
    ) async throws -> BundleSinkResult {
        let sigData = Self.hexToData(signature)
        guard sigData.count == 64 else {
            throw VerificationFailure.manifestSignatureInvalid
        }

        // Step 1: Manifest signature verification
        let result = try verifier.verifyManifestSignature(
            manifestBytes: manifest,
            signature: sigData,
            devicePublicKey: devicePublicKey
        )
        Self.log.notice("step 1 pass: manifest signature verified, \(result.memberCount) members, \(result.chunkCount) chunks")

        let bundleIDHex = result.bundleID.map { String(format: "%02x", $0) }.joined()

        // Check if already imported
        let dest = bundleDir.appendingPathComponent(bundleIDHex)
        if FileManager.default.fileExists(atPath: dest.appendingPathComponent("manifest.cbor").path) {
            Self.log.notice("bundle \(bundleIDHex) already imported")
            return BundleSinkResult(alreadyStored: true)
        }

        // Step 2: Content root recomputation
        try verifier.verifyContentRoot(manifestBytes: manifest)
        Self.log.notice("step 2 pass: content root verified")

        // Decode manifest to get chunk descriptors
        let decoded = try Self.decodeManifest(manifest)

        // Step 3: Read and verify each chunk
        let staging = bundleDir.appendingPathComponent("staging-\(bundleIDHex)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        var offset: Int64 = 0
        for i in 0..<decoded.chunkCount {
            let chunkLen = Int64(decoded.chunks[i].byteLength)
            let chunkData = try await readChunk(offset, chunkLen)
            try verifier.verifyChunkDigest(
                chunkData: chunkData,
                expectedDigest: decoded.chunks[i].sha256,
                index: i
            )
            let chunkFile = staging.appendingPathComponent("chunk-\(i)")
            try chunkData.write(to: chunkFile)
            offset += chunkLen
            onChunk(i + 1, decoded.chunkCount, chunkLen)
        }
        Self.log.notice("step 3 pass: all \(decoded.chunkCount) chunk digests verified")

        // Assemble members from chunks
        let assembled = try Self.assembleMembers(staging: staging, decoded: decoded)

        // Step 4: Structural scan of each segment member
        for member in assembled {
            let scanResult = try verifier.structuralScan(segmentData: member.data)
            Self.log.notice("step 4 pass: structural scan of \(member.name) — \(scanResult.frames) frames, stop=\(String(cString: bealach_stop_reason_name(scanResult.stop)))")
        }

        // Step 5: Keyed AEAD scan
        for member in assembled {
            let scanResult = try verifier.keyedScan(segmentData: member.data, rootKey: rootKey)
            Self.log.notice("step 5 pass: AEAD scan of \(member.name) — \(scanResult.frames) authenticated frames")
        }

        // Step 6: Transactional durable import
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try manifest.write(to: dest.appendingPathComponent("manifest.cbor"))
        try sigData.write(to: dest.appendingPathComponent("manifest.sig"))
        for member in assembled {
            try member.data.write(to: dest.appendingPathComponent(member.name))
        }
        try FileManager.default.removeItem(at: staging)

        try await db.dbPool.write { dbConn in
            try dbConn.execute(sql: """
                INSERT OR REPLACE INTO mirrorEntry (bundleID, contentRoot, manifestHash, memberCount, totalBytes, verifiedAt)
                VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [
                bundleIDHex,
                result.contentRoot.map { String(format: "%02x", $0) }.joined(),
                result.manifestHash.map { String(format: "%02x", $0) }.joined(),
                result.memberCount,
                Int64(result.totalBytes),
                Date()
            ])
        }

        Self.log.notice("step 6 complete: bundle \(bundleIDHex) durably imported")

        // Build and sign receipt
        let receipt = try Self.buildReceipt(
            result: result,
            devicePublicKey: devicePublicKey,
            ownerSeed: ownerSeed,
            ownerPublicKey: ownerPublicKey
        )

        return BundleSinkResult(receipt: OffloadReceipt(bytes: receipt), chunksRead: decoded.chunkCount)
    }

    // MARK: - Helpers

    private struct DecodedManifest {
        struct Chunk {
            let index: UInt32
            let byteLength: UInt32
            let sha256: Data
        }
        struct Member {
            let name: String
            let length: UInt64
        }
        let chunkCount: Int
        let chunks: [Chunk]
        let memberCount: Int
        let members: [Member]
        let bundleID: Data
    }

    private struct AssembledMember {
        let name: String
        let data: Data
    }

    private static let manifestScratchSize = 2048 + (Int(BEALACH_MAX_MEMBERS) * 96) + (Int(BEALACH_MAX_CHUNKS) * 48)

    private static func decodeManifest(_ manifestBytes: Data) throws -> DecodedManifest {
        var manifest = bealach_manifest_t()
        var scratch = Data(count: manifestScratchSize)
        let err = manifestBytes.withUnsafeBytes { manifestPtr in
            scratch.withUnsafeMutableBytes { scratchPtr in
                bealach_manifest_decode(
                    manifestPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    manifestBytes.count,
                    &manifest,
                    scratchPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    scratchPtr.count
                )
            }
        }
        guard err == BEALACH_OK else {
            throw VerificationFailure.manifestDecodeFailed(String(cString: bealach_strerror(err)))
        }

        var chunks: [DecodedManifest.Chunk] = []
        withUnsafePointer(to: &manifest.chunks) { tuple in
            tuple.withMemoryRebound(to: bealach_chunk_t.self, capacity: Int(BEALACH_MAX_CHUNKS)) { ptr in
                for i in 0..<manifest.chunk_count {
                    let c = ptr[i]
                    let sha = withUnsafeBytes(of: c.sha256) { Data($0) }
                    chunks.append(.init(index: c.index, byteLength: c.byte_length, sha256: sha))
                }
            }
        }

        var members: [DecodedManifest.Member] = []
        withUnsafePointer(to: &manifest.members) { tuple in
            tuple.withMemoryRebound(to: bealach_member_t.self, capacity: Int(BEALACH_MAX_MEMBERS)) { ptr in
                for i in 0..<manifest.member_count {
                    let m = ptr[i]
                    let name = withUnsafeBytes(of: m.name) { buf in
                        let raw = buf.bindMemory(to: CChar.self)
                        return String(cString: raw.baseAddress!)
                    }
                    members.append(.init(name: name, length: m.length))
                }
            }
        }

        let bundleID = withUnsafeBytes(of: manifest.bundle_id) { Data($0) }

        return DecodedManifest(
            chunkCount: manifest.chunk_count,
            chunks: chunks,
            memberCount: manifest.member_count,
            members: members,
            bundleID: bundleID
        )
    }

    private static func assembleMembers(staging: URL, decoded: DecodedManifest) throws -> [AssembledMember] {
        var allData = Data()
        for i in 0..<decoded.chunkCount {
            let chunkFile = staging.appendingPathComponent("chunk-\(i)")
            try allData.append(Data(contentsOf: chunkFile))
        }

        var assembled: [AssembledMember] = []
        var offset = 0
        for member in decoded.members {
            let end = offset + Int(member.length)
            guard end <= allData.count else {
                throw VerificationFailure.structuralScanFailed(
                    reason: "member \(member.name) extends past assembled data (\(end) > \(allData.count))"
                )
            }
            assembled.append(.init(name: member.name, data: allData[offset..<end]))
            offset = end
        }
        return assembled
    }

    private static func buildReceipt(
        result: VerificationResult,
        devicePublicKey: Data,
        ownerSeed: Data,
        ownerPublicKey: Data
    ) throws -> Data {
        var receipt = bealach_receipt_t()
        receipt.receipt_version = UInt8(BEALACH_RECEIPT_VERSION)
        var uuid = UUID().uuid
        withUnsafeBytes(of: &uuid) { ptr in
            _ = memcpy(&receipt.receipt_id, ptr.baseAddress!, 16)
        }
        result.bundleID.withUnsafeBytes { ptr in
            _ = memcpy(&receipt.device_id, ptr.baseAddress!, min(ptr.count, 16))
        }
        result.bundleID.withUnsafeBytes { ptr in
            _ = memcpy(&receipt.bundle_id, ptr.baseAddress!, min(ptr.count, 16))
        }
        result.contentRoot.withUnsafeBytes { ptr in
            _ = memcpy(&receipt.content_root, ptr.baseAddress!, min(ptr.count, 32))
        }
        receipt.server_ingest_utc_ms = UInt64(Date().timeIntervalSince1970 * 1000)
        receipt.ingest_schema_version = 1

        var keyID = Data(count: 8)
        ownerPublicKey.withUnsafeBytes { pubPtr in
            keyID.withUnsafeMutableBytes { idPtr in
                bealach_device_key_id(
                    pubPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    idPtr.baseAddress?.assumingMemoryBound(to: UInt8.self)
                )
            }
        }
        keyID.withUnsafeBytes { ptr in
            _ = memcpy(&receipt.server_key_id, ptr.baseAddress!, 8)
        }

        withUnsafeMutableBytes(of: &receipt.signature_algorithm) { buf in
            let algo = "ed25519"
            algo.utf8.withContiguousStorageIfAvailable { src in
                _ = memcpy(buf.baseAddress!, src.baseAddress!, src.count)
            }
        }

        // Sign
        var signingBuf = Data(count: 512)
        var signingLen: Int = 0
        let sigErr = signingBuf.withUnsafeMutableBytes { bufPtr in
            bealach_receipt_signing_bytes(
                &receipt,
                bufPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                bufPtr.count,
                &signingLen
            )
        }
        guard sigErr == BEALACH_OK else {
            throw VerificationFailure.manifestDecodeFailed("receipt signing bytes failed")
        }

        let signingData = signingBuf.prefix(signingLen)
        signingData.withUnsafeBytes { msgPtr in
            ownerSeed.withUnsafeBytes { seedPtr in
                ownerPublicKey.withUnsafeBytes { pubPtr in
                    bealach_ed25519_sign(
                        msgPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        msgPtr.count,
                        seedPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        pubPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        &receipt.signature.0
                    )
                }
            }
        }

        // Encode
        var encoded = Data(count: 1024)
        var encodedLen: Int = 0
        let encErr = encoded.withUnsafeMutableBytes { bufPtr in
            bealach_receipt_encode(
                &receipt,
                bufPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                bufPtr.count,
                &encodedLen
            )
        }
        guard encErr == BEALACH_OK else {
            throw VerificationFailure.manifestDecodeFailed("receipt encode failed")
        }

        return Data(encoded.prefix(encodedLen))
    }

    private static func hexToData(_ hex: String) -> Data {
        let chars = Array(hex)
        var data = Data(capacity: chars.count / 2)
        for i in stride(from: 0, to: chars.count - 1, by: 2) {
            guard let byte = UInt8(String(chars[i...i+1]), radix: 16) else { continue }
            data.append(byte)
        }
        return data
    }
}
