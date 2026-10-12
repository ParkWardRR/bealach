import BealachCore
import CryptoKit
import Foundation
import Testing

@Suite struct EnrolmentServiceIdentityTests {
    private static let sampleDeviceID = Data(repeating: 0xA0, count: 16)
    private static let sampleFingerprint = "5fd41190"

    private func sampleIdentity(ownerKeyHex: String = "aabbccdd") -> EnrolledIdentity {
        EnrolledIdentity(
            deviceID: Self.sampleDeviceID,
            fingerprint: Self.sampleFingerprint,
            ownerKeyHex: ownerKeyHex
        )
    }

    @Test func loadIdentityReturnsStoredState() async throws {
        let store = InMemoryIdentityStore()
        let keyProvider = SoftwareKeyProvider()
        let identity = sampleIdentity(ownerKeyHex: keyProvider.publicKeyHex)
        try await store.save(state: .enrolled, identity: identity)

        let service = EnrolmentService(keyProvider: keyProvider, identityStore: store)
        let (state, loaded) = await service.loadIdentity()
        #expect(state == .enrolled)
        #expect(loaded?.fingerprint == Self.sampleFingerprint)
        #expect(loaded?.deviceID == Self.sampleDeviceID)
    }

    @Test func enrolSavesIdentity() async throws {
        let store = InMemoryIdentityStore()
        let keyProvider = SoftwareKeyProvider()
        let service = EnrolmentService(keyProvider: keyProvider, identityStore: store)

        let identity = sampleIdentity(ownerKeyHex: keyProvider.publicKeyHex)
        try await service.enrol(identity: identity)

        let (state, loaded) = await service.loadIdentity()
        #expect(state == .enrolled)
        #expect(loaded?.fingerprint == Self.sampleFingerprint)
    }

    @Test func resetClearsIdentityAndKey() async throws {
        let store = InMemoryIdentityStore()
        let keyProvider = SoftwareKeyProvider()
        try await store.save(state: .enrolled, identity: sampleIdentity(ownerKeyHex: keyProvider.publicKeyHex))

        let service = EnrolmentService(keyProvider: keyProvider, identityStore: store)
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
        func deleteKey() throws { throw EnrolmentError.keyInstallFailed }
    }

    @Test func resetClearsTheEnrolmentEvenWhenTheKeyCannotBeReplaced() async throws {
        let store = InMemoryIdentityStore()
        let key = KeyThatCannotBeReplaced()
        try await store.save(state: .enrolled, identity: sampleIdentity(ownerKeyHex: key.publicKeyHex))
        let service = EnrolmentService(keyProvider: key, identityStore: store)

        await #expect(throws: EnrolmentError.self) { try await service.reset() }

        let (state, loaded) = await service.loadIdentity()
        #expect(state == .notEnrolled)
        #expect(loaded == nil)
    }

    @Test func resetWorksFromMultipleStates() async throws {
        for stored in [EnrolmentState.needsReenrolment, .enrolled] {
            let store = InMemoryIdentityStore()
            let keyProvider = SoftwareKeyProvider()
            let ownerKey = stored == .needsReenrolment ? "stale-key" : keyProvider.publicKeyHex
            try await store.save(
                state: stored == .needsReenrolment ? .enrolled : stored,
                identity: sampleIdentity(ownerKeyHex: ownerKey)
            )
            let service = EnrolmentService(keyProvider: keyProvider, identityStore: store)
            try await service.reset()
            let (state, _) = await service.loadIdentity()
            #expect(state == .notEnrolled, "from \(stored)")
        }
    }

    @Test func anIdentityEnrolledWithAnotherKeyNeedsReenrolment() async throws {
        let store = InMemoryIdentityStore()
        let earlierKey = SoftwareKeyProvider()
        try await store.save(state: .enrolled, identity: sampleIdentity(ownerKeyHex: earlierKey.publicKeyHex))

        let service = EnrolmentService(keyProvider: SoftwareKeyProvider(), identityStore: store)
        let (state, loaded) = await service.loadIdentity()
        #expect(state == .needsReenrolment)
        #expect(loaded?.fingerprint == Self.sampleFingerprint)
    }

    @Test func deviceIDHexFormatsCorrectly() {
        let id = Data([0x0a, 0xb1, 0xc2, 0xd3, 0xe4, 0xf5, 0x06, 0x17,
                       0x28, 0x39, 0x4a, 0x5b, 0x6c, 0x7d, 0x8e, 0x9f])
        let identity = EnrolledIdentity(deviceID: id, fingerprint: "abcd1234", ownerKeyHex: "key")
        #expect(identity.deviceIDHex == "0ab1c2d3e4f5061728394a5b6c7d8e9f")
    }

    @Test func identityRoundTripsViaJSON() throws {
        let identity = sampleIdentity(ownerKeyHex: "deadbeef")
        let data = try JSONEncoder().encode(identity)
        let decoded = try JSONDecoder().decode(EnrolledIdentity.self, from: data)
        #expect(decoded == identity)
    }
}
