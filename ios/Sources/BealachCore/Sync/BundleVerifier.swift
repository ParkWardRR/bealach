import BealachFormat
import CryptoKit
import Foundation

// Swift can't import the compound #define; mirror the C formula.
private let manifestEncodedMax = 2048 + (Int(BEALACH_MAX_MEMBERS) * 96) + (Int(BEALACH_MAX_CHUNKS) * 48)

public enum VerificationStep: String, Sendable, CaseIterable {
    case manifestSignature = "manifest-signature"
    case contentRoot = "content-root"
    case chunkDigests = "chunk-digests"
    case structuralScan = "structural-scan"
    case aeadAuthentication = "aead-authentication"
    case import_ = "import"
}

public enum VerificationFailure: Error, Sendable, Equatable {
    case manifestSignatureInvalid
    case manifestDecodeFailed(String)
    case contentRootMismatch
    case chunkDigestMismatch(index: Int)
    case structuralScanFailed(reason: String)
    case aeadAuthenticationFailed(segment: String)
    case noRootKey
}

public struct VerificationResult: Sendable {
    public let bundleID: Data
    public let contentRoot: Data
    public let manifestHash: Data
    public let chunkCount: Int
    public let memberCount: Int
    public let totalBytes: UInt64

    public init(bundleID: Data, contentRoot: Data, manifestHash: Data,
                chunkCount: Int, memberCount: Int, totalBytes: UInt64) {
        self.bundleID = bundleID
        self.contentRoot = contentRoot
        self.manifestHash = manifestHash
        self.chunkCount = chunkCount
        self.memberCount = memberCount
        self.totalBytes = totalBytes
    }
}

public struct BundleVerifier: Sendable {
    public init() {}

    public func verifyManifestSignature(
        manifestBytes: Data,
        signature: Data,
        devicePublicKey: Data
    ) throws -> VerificationResult {
        guard signature.count == 64, devicePublicKey.count == 32 else {
            throw VerificationFailure.manifestSignatureInvalid
        }

        let valid = manifestBytes.withUnsafeBytes { manifestPtr in
            signature.withUnsafeBytes { sigPtr in
                devicePublicKey.withUnsafeBytes { keyPtr in
                    bealach_manifest_verify(
                        manifestPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        manifestBytes.count,
                        sigPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        keyPtr.baseAddress?.assumingMemoryBound(to: UInt8.self)
                    )
                }
            }
        }

        guard valid == BEALACH_OK else {
            throw VerificationFailure.manifestSignatureInvalid
        }

        var manifest = bealach_manifest_t()
        var scratch = Data(count: manifestEncodedMax)
        let decodeResult = manifestBytes.withUnsafeBytes { manifestPtr in
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

        guard decodeResult == BEALACH_OK else {
            throw VerificationFailure.manifestDecodeFailed(
                String(cString: bealach_strerror(decodeResult))
            )
        }

        let bundleID = withUnsafeBytes(of: &manifest.bundle_id) { Data($0) }
        let contentRoot = withUnsafeBytes(of: &manifest.content_root) { Data($0) }

        var manifestHash = Data(count: 32)
        manifestBytes.withUnsafeBytes { ptr in
            manifestHash.withUnsafeMutableBytes { hashPtr in
                bealach_sha256(
                    ptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    manifestBytes.count,
                    hashPtr.baseAddress?.assumingMemoryBound(to: UInt8.self)
                )
            }
        }

        var totalBytes: UInt64 = 0
        withUnsafePointer(to: &manifest.members) { tuple in
            tuple.withMemoryRebound(to: bealach_member_t.self, capacity: Int(BEALACH_MAX_MEMBERS)) { members in
                for i in 0..<manifest.member_count {
                    totalBytes += members[i].length
                }
            }
        }

        return VerificationResult(
            bundleID: bundleID,
            contentRoot: contentRoot,
            manifestHash: manifestHash,
            chunkCount: manifest.chunk_count,
            memberCount: manifest.member_count,
            totalBytes: totalBytes
        )
    }

    public func verifyContentRoot(manifestBytes: Data) throws {
        var manifest = bealach_manifest_t()
        var scratch = Data(count: manifestEncodedMax)
        let decodeResult = manifestBytes.withUnsafeBytes { manifestPtr in
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
        guard decodeResult == BEALACH_OK else {
            throw VerificationFailure.manifestDecodeFailed(
                String(cString: bealach_strerror(decodeResult))
            )
        }

        let rootResult = bealach_manifest_verify_content_root(&manifest)
        guard rootResult == BEALACH_OK else {
            throw VerificationFailure.contentRootMismatch
        }
    }

    public func verifyChunkDigest(chunkData: Data, expectedDigest: Data, index: Int) throws {
        guard expectedDigest.count == 32 else {
            throw VerificationFailure.chunkDigestMismatch(index: index)
        }

        var computed = Data(count: 32)
        chunkData.withUnsafeBytes { ptr in
            computed.withUnsafeMutableBytes { hashPtr in
                bealach_sha256(
                    ptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    chunkData.count,
                    hashPtr.baseAddress?.assumingMemoryBound(to: UInt8.self)
                )
            }
        }

        guard computed == expectedDigest else {
            throw VerificationFailure.chunkDigestMismatch(index: index)
        }
    }

    public func structuralScan(
        segmentData: Data
    ) throws -> bealach_scan_result_t {
        var result = bealach_scan_result_t()
        let state = bealach_scan_state_t(expected_seq: 0, expected_prev: 0)

        let scanResult = segmentData.withUnsafeBytes { ptr in
            bealach_scan_segment(
                ptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                segmentData.count,
                state,
                nil,
                &result
            )
        }

        guard scanResult == BEALACH_OK else {
            throw VerificationFailure.structuralScanFailed(
                reason: String(cString: bealach_strerror(scanResult))
            )
        }

        return result
    }

    public func keyedScan(
        segmentData: Data,
        rootKey: Data,
        state: bealach_scan_state_t = bealach_scan_state_t(expected_seq: 0, expected_prev: 0)
    ) throws -> bealach_scan_result_t {
        guard rootKey.count == 32 else {
            throw VerificationFailure.noRootKey
        }

        var result = bealach_scan_result_t()
        var rootKeyData = bealach_root_key_t()
        rootKey.withUnsafeBytes { ptr in
            _ = memcpy(&rootKeyData.root, ptr.baseAddress!, 32)
        }
        rootKeyData.version = 1

        let scanResult = withUnsafeMutablePointer(to: &rootKeyData) { keyPtr in
            var opts = bealach_scan_opts_t()
            opts.key = bealach_root_key_provider
            opts.key_user = UnsafeMutableRawPointer(keyPtr)
            return segmentData.withUnsafeBytes { ptr in
                bealach_scan_segment(
                    ptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    segmentData.count,
                    state,
                    &opts,
                    &result
                )
            }
        }

        guard scanResult == BEALACH_OK else {
            throw VerificationFailure.aeadAuthenticationFailed(
                segment: String(cString: bealach_strerror(scanResult))
            )
        }

        if result.stop == BEALACH_STOP_AUTH_FAILED {
            throw VerificationFailure.aeadAuthenticationFailed(
                segment: "frame authentication failed"
            )
        }

        return result
    }
}
