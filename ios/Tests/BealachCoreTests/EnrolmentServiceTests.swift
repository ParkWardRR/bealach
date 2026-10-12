// Provenance: cairn-ios-companion-app @ a7d02d8, Tests/CairnCoreTests/EnrolmentServiceTests.swift
// Renamed Cairn* → Bealach* for Bealach.
// Server-based enrolment tests removed: Bealach uses device-to-owner-phone trust, not server enrolment.

import BealachCore
import CryptoKit
import Foundation
import Testing

// MARK: - Identity management tests (no server required)

@Suite struct EnrolmentServiceIdentityTests {
    @Test func loadIdentityReturnsStoredState() async throws {
        let store = InMemoryIdentityStore()
        let keyProvider = SoftwareKeyProvider()
        let identity = EnrolledIdentity(
            clientID: "abc123", role: "admin", scope: ["*"],
            instanceID: "inst1", spkiSHA256: "spki",
            localBaseURL: "https://cairn.example.lan",
            tailnetBaseURL: "https://cairn.ts.net",
            publicKeyHex: keyProvider.publicKeyHex
        )
        try await store.save(state: .enrolled, identity: identity)

        let service = EnrolmentService(
            keyProvider: keyProvider,
            identityStore: store
        )

        let (state, loaded) = await service.loadIdentity()
        #expect(state == .enrolled)
        #expect(loaded?.clientID == "abc123")
        #expect(loaded?.isAdmin == true)
    }

    @Test func resetClearsIdentityAndKey() async throws {
        let store = InMemoryIdentityStore()
        let identity = EnrolledIdentity(
            clientID: "abc", role: "user", scope: ["v1"],
            instanceID: "i1", spkiSHA256: "s1",
            localBaseURL: "", tailnetBaseURL: ""
        )
        try await store.save(state: .enrolled, identity: identity)

        let service = EnrolmentService(
            keyProvider: SoftwareKeyProvider(),
            identityStore: store
        )

        try await service.reset()

        let (state, loaded) = await service.loadIdentity()
        #expect(state == .notEnrolled)
        #expect(loaded == nil)
    }

    private struct KeyThatCannotBeReplaced: KeyProvider {
        let inner = SoftwareKeyProvider()
        var publicKeyX963: Data { inner.publicKeyX963 }
        var publicKeyHex: String { inner.publicKeyHex }
        func sign(_ data: Data) throws -> Data { try inner.sign(data) }
        func deleteKey() throws { throw EnrolmentError.proofSigningFailed }
    }

    @Test func resetClearsTheEnrolmentEvenWhenTheKeyCannotBeReplaced() async throws {
        let store = InMemoryIdentityStore()
        let key = KeyThatCannotBeReplaced()
        try await store.save(state: .enrolled, identity: EnrolledIdentity(
            clientID: "abc", role: "user", scope: ["*"], instanceID: "i", spkiSHA256: "s",
            localBaseURL: "", tailnetBaseURL: "", publicKeyHex: key.publicKeyHex
        ))
        let service = EnrolmentService(keyProvider: key, identityStore: store)

        await #expect(throws: EnrolmentError.self) { try await service.reset() }

        let (state, loaded) = await service.loadIdentity()
        #expect(state == .notEnrolled)
        #expect(loaded == nil)
    }

    @Test func resetWorksFromTheStatesThatAskedForIt() async throws {
        for stored in [EnrolmentState.revoked, .needsReenrolment, .enrolled] {
            let store = InMemoryIdentityStore()
            try await store.save(state: stored == .needsReenrolment ? .enrolled : stored, identity: EnrolledIdentity(
                clientID: "abc", role: "user", scope: ["*"], instanceID: "i", spkiSHA256: "s",
                localBaseURL: "", tailnetBaseURL: "", publicKeyHex: stored == .needsReenrolment ? "00" : nil
            ))
            let service = EnrolmentService(keyProvider: SoftwareKeyProvider(), identityStore: store)
            try await service.reset()
            let (state, _) = await service.loadIdentity()
            #expect(state == .notEnrolled, "from \(stored)")
        }
    }

    @Test func makeSignerReturnsNilWhenNotEnrolled() async throws {
        let service = EnrolmentService(
            keyProvider: SoftwareKeyProvider(),
            identityStore: InMemoryIdentityStore()
        )

        let signer = await service.makeSigner()
        #expect(signer == nil)
    }

    @Test func makeSignerReturnsValidSignerWhenEnrolled() async throws {
        let keyProvider = SoftwareKeyProvider()
        let store = InMemoryIdentityStore()
        let identity = EnrolledIdentity(
            clientID: "deadbeef", role: "admin", scope: ["*"],
            instanceID: "i1", spkiSHA256: "s1",
            localBaseURL: "", tailnetBaseURL: "",
            publicKeyHex: keyProvider.publicKeyHex
        )
        try await store.save(state: .enrolled, identity: identity)

        let service = EnrolmentService(keyProvider: keyProvider, identityStore: store)
        let signer = await service.makeSigner()

        #expect(signer != nil)
        #expect(signer?.clientID == "deadbeef")
        #expect(signer?.publicKeyX963 == keyProvider.publicKeyX963)

        let testData = Data("test message".utf8)
        let signature = try signer!.sign(testData)
        let pubKey = try P256.Signing.PublicKey(x963Representation: keyProvider.publicKeyX963)
        let sig = try P256.Signing.ECDSASignature(derRepresentation: signature)
        #expect(pubKey.isValidSignature(sig, for: testData))
    }

    // The bug this guards against: the Secure Enclave key was never saved, so each launch made a
    // new key and every signed request was refused with 401 signature_does_not_verify.
    @Test func anIdentityEnrolledWithAnotherKeyNeedsReenrolmentAndGetsNoSigner() async throws {
        let store = InMemoryIdentityStore()
        let earlierKey = SoftwareKeyProvider()
        let identity = EnrolledIdentity(
            clientID: "abc", role: "user", scope: ["*"], instanceID: "i1", spkiSHA256: "s1",
            localBaseURL: "", tailnetBaseURL: "", publicKeyHex: earlierKey.publicKeyHex
        )
        try await store.save(state: .enrolled, identity: identity)

        let service = EnrolmentService(keyProvider: SoftwareKeyProvider(), identityStore: store)
        let (state, loaded) = await service.loadIdentity()
        #expect(state == .needsReenrolment)
        #expect(loaded?.clientID == "abc")
        #expect(await service.makeSigner() == nil)
    }

    @Test func anIdentitySavedBeforeKeysWereKeptNeedsReenrolment() async throws {
        let store = InMemoryIdentityStore()
        let identity = EnrolledIdentity(
            clientID: "abc", role: "user", scope: ["*"], instanceID: "i1", spkiSHA256: "s1",
            localBaseURL: "", tailnetBaseURL: ""
        )
        try await store.save(state: .enrolled, identity: identity)

        let service = EnrolmentService(keyProvider: SoftwareKeyProvider(), identityStore: store)
        let (state, _) = await service.loadIdentity()
        #expect(state == .needsReenrolment)
    }

    @Test func aStoredIdentityWithoutAKeyStillDecodes() throws {
        let old = Data("""
        {"clientID":"abc","role":"user","scope":["*"],"instanceID":"i","spkiSHA256":"s","localBaseURL":"","tailnetBaseURL":""}
        """.utf8)
        let identity = try JSONDecoder().decode(EnrolledIdentity.self, from: old)
        #expect(identity.publicKeyHex == nil)
    }

    @Test func markRevoked() async throws {
        let store = InMemoryIdentityStore()
        let keyProvider = SoftwareKeyProvider()
        let identity = EnrolledIdentity(
            clientID: "abc", role: "admin", scope: ["*"],
            instanceID: "i1", spkiSHA256: "s1",
            localBaseURL: "", tailnetBaseURL: "",
            publicKeyHex: keyProvider.publicKeyHex
        )
        try await store.save(state: .enrolled, identity: identity)

        let service = EnrolmentService(
            keyProvider: keyProvider,
            identityStore: store
        )

        try await service.markRevoked()

        let (state, loaded) = await service.loadIdentity()
        #expect(state == .revoked)
        #expect(loaded?.clientID == "abc")
    }
}
