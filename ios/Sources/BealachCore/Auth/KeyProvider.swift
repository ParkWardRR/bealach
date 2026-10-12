// Provenance: cairn-ios-companion-app @ a7d02d8, Sources/CairnCore/Auth/KeyProvider.swift
// Renamed Cairn* → Bealach* for Bealach.

import CryptoKit
import Foundation

public protocol KeyProvider: Sendable {
    var publicKeyX963: Data { get }
    var publicKeyHex: String { get }
    func sign(_ data: Data) throws -> Data
    func deleteKey() throws
}

/// Signs outgoing requests with the device key. Bealach keeps this protocol for the auth
/// subsystem even though there is no server to sign requests to; the owner's phone is the
/// verifier instead.
public protocol RequestSigner: Sendable {
    var clientID: String { get }
    var publicKeyX963: Data { get }
    func sign(_ data: Data) throws -> Data
}

public struct KeyProviderSigner: RequestSigner, @unchecked Sendable {
    private let provider: any KeyProvider
    public let clientID: String
    public var publicKeyX963: Data { provider.publicKeyX963 }

    public init(provider: any KeyProvider, clientID: String) {
        self.provider = provider
        self.clientID = clientID
    }

    public func sign(_ data: Data) throws -> Data {
        try provider.sign(data)
    }
}

public final class SoftwareKeyProvider: KeyProvider, @unchecked Sendable {
    private let privateKey: P256.Signing.PrivateKey

    public var publicKeyX963: Data {
        Data(privateKey.publicKey.x963Representation)
    }

    public var publicKeyHex: String {
        publicKeyX963.map { String(format: "%02x", $0) }.joined()
    }

    public init(privateKey: P256.Signing.PrivateKey = .init()) {
        self.privateKey = privateKey
    }

    public func sign(_ data: Data) throws -> Data {
        try privateKey.signature(for: data).derRepresentation
    }

    public func deleteKey() throws {}
}
