// Provenance: cairn-ios-companion-app @ a7d02d8, Sources/CairnCore/Auth/EnrolmentService.swift
// Renamed Cairn* → Bealach* for Bealach.

import Foundation

/// Manages device enrolment state. In Bealach the trust model is device-to-owner-phone
/// (no server), so the server-based enrolment flow is removed. The identity store and key
/// provider remain for local proof-of-possession.
public actor EnrolmentService {
    private let keyProvider: any KeyProvider
    private let identityStore: any IdentityStore

    public init(keyProvider: any KeyProvider, identityStore: any IdentityStore) {
        self.keyProvider = keyProvider
        self.identityStore = identityStore
    }

    // Server-based enrol() removed: Bealach uses device-to-owner-phone trust, not server enrolment.

    /// The stored identity, except that an enrolled one whose registered key is not the key this
    /// phone holds now is reported as `.needsReenrolment`: its requests could only fail.
    public func loadIdentity() async -> (EnrolmentState, EnrolledIdentity?) {
        let (state, identity) = await identityStore.load()
        if state == .enrolled, let identity, identity.publicKeyHex != keyProvider.publicKeyHex {
            return (.needsReenrolment, identity)
        }
        return (state, identity)
    }

    public func markRevoked() async throws {
        let (_, identity) = await identityStore.load()
        try await identityStore.save(state: .revoked, identity: identity)
    }

    /// Forgets the enrolment, then replaces the key. The enrolment goes first so a key that
    /// cannot be replaced still leaves the phone able to enrol again, rather than stuck.
    public func reset() async throws {
        try await identityStore.clear()
        try keyProvider.deleteKey()
    }

    /// Build a signer from the stored identity and key provider.
    public func makeSigner() async -> (any RequestSigner)? {
        let (state, identity) = await loadIdentity()
        guard state == .enrolled, let identity else { return nil }
        return KeyProviderSigner(provider: keyProvider, clientID: identity.clientID)
    }
}

public enum EnrolmentError: Error, Sendable {
    case proofSigningFailed
    case notEnrolled
}
