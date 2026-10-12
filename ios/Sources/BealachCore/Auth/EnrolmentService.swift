import Foundation

/// Manages device enrolment state. In Bealach the trust model is device-to-owner-phone
/// (no server): the phone holds Ed25519/X25519 keys whose public halves are installed on
/// the dongle via the provisioning console.
public actor EnrolmentService {
    private let keyProvider: any KeyProvider
    private let identityStore: any IdentityStore

    public init(keyProvider: any KeyProvider, identityStore: any IdentityStore) {
        self.keyProvider = keyProvider
        self.identityStore = identityStore
    }

    /// The stored identity. An enrolled identity whose owner key no longer matches the key
    /// this phone holds is reported as `.needsReenrolment`.
    public func loadIdentity() async -> (EnrolmentState, EnrolledIdentity?) {
        let (state, identity) = await identityStore.load()
        if state == .enrolled, let identity, identity.ownerKeyHex != keyProvider.publicKeyHex {
            return (.needsReenrolment, identity)
        }
        return (state, identity)
    }

    /// Record a successful BLE enrolment.
    public func enrol(identity: EnrolledIdentity) async throws {
        try await identityStore.save(state: .enrolled, identity: identity)
    }

    /// Forgets the enrolment, then replaces the key. The enrolment goes first so a key that
    /// cannot be replaced still leaves the phone able to enrol again, rather than stuck.
    public func reset() async throws {
        try await identityStore.clear()
        try keyProvider.deleteKey()
    }
}

public enum EnrolmentError: Error, Sendable {
    case fingerprintMismatch
    case bleConnectionFailed
    case keyInstallFailed
    case notEnrolled
}
