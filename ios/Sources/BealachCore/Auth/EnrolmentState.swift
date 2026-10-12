import Foundation

public enum EnrolmentState: String, Codable, Sendable {
    case notEnrolled
    case enrolling
    case enrolled
    /// The identity on file was enrolled with a key this phone no longer holds (or one that was
    /// never saved). Only a fresh enrolment fixes it.
    case needsReenrolment
}

/// The relationship between this phone and an enrolled dongle. In Bealach the trust model is
/// device-to-owner-phone (no server): the phone holds Ed25519 and X25519 key pairs whose public
/// halves are installed on the dongle via `SET owner_keys`.
public struct EnrolledIdentity: Codable, Sendable, Equatable {
    /// 16-byte UUID of the enrolled dongle (from `DEVICE_INFO` identity).
    public var deviceID: Data
    /// 8-character hex fingerprint derived from the dongle's Ed25519 public key.
    public var fingerprint: String
    /// The phone's Ed25519 public key hex (the `pinned_key` installed on the dongle for receipt
    /// verification). Used to detect key mismatch after a key rotation or restore.
    public var ownerKeyHex: String
    /// When the enrolment bond was established.
    public var enrolledAt: Date

    public init(
        deviceID: Data,
        fingerprint: String,
        ownerKeyHex: String,
        enrolledAt: Date = Date()
    ) {
        self.deviceID = deviceID
        self.fingerprint = fingerprint
        self.ownerKeyHex = ownerKeyHex
        self.enrolledAt = enrolledAt
    }

    public var deviceIDHex: String {
        deviceID.map { String(format: "%02x", $0) }.joined()
    }
}
