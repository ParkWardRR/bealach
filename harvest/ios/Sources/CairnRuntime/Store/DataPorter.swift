import CairnCore
import CryptoKit
import Foundation
import GRDB

public final class DataPorter: Sendable {
    private let db: CairnDatabase
    private let vehicleStore: GRDBVehicleStore
    private let maintenanceStore: GRDBMaintenanceStore

    public init(db: CairnDatabase, vehicleStore: GRDBVehicleStore, maintenanceStore: GRDBMaintenanceStore) {
        self.db = db
        self.vehicleStore = vehicleStore
        self.maintenanceStore = maintenanceStore
    }

    // MARK: - Export

    public func exportData(passphrase: String) async throws -> Data {
        let vehicles = try await vehicleStore.listVehicles()
        let assignments = try await vehicleStore.assignments()

        var allMaintenance: [MaintenanceEntry] = []
        var allOdometer: [OdometerCorrection] = []
        var allAnnotations: [Annotation] = []

        for vehicle in vehicles {
            let entries = try await maintenanceStore.listEntries(vehicleID: vehicle.id)
            allMaintenance.append(contentsOf: entries)
            let corrections = try await maintenanceStore.listOdometerCorrections(vehicleID: vehicle.id)
            allOdometer.append(contentsOf: corrections)
        }
        allAnnotations = try await maintenanceStore.listAnnotations(vehicleID: nil)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        let payload = ExportPayload(
            version: 1,
            exportedAt: Date(),
            vehicles: vehicles,
            assignments: assignments,
            maintenance: allMaintenance,
            odometer: allOdometer,
            annotations: allAnnotations
        )

        let json = try encoder.encode(payload)
        return try Self.encrypt(json, passphrase: passphrase)
    }

    // MARK: - Import

    public func importData(_ encrypted: Data, passphrase: String) async throws -> ImportSummary {
        let json = try Self.decrypt(encrypted, passphrase: passphrase)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(ExportPayload.self, from: json)

        var vehiclesImported = 0
        var maintenanceImported = 0
        var odometerImported = 0
        var annotationsImported = 0

        for vehicle in payload.vehicles {
            try await vehicleStore.saveVehicle(vehicle)
            vehiclesImported += 1
        }

        for assignment in payload.assignments {
            try await vehicleStore.assign(dongleID: assignment.dongleID, to: assignment.vehicleID)
        }

        for entry in payload.maintenance {
            try await maintenanceStore.saveEntry(entry)
            maintenanceImported += 1
        }

        for correction in payload.odometer {
            try await maintenanceStore.saveOdometerCorrection(correction)
            odometerImported += 1
        }

        for annotation in payload.annotations {
            try await maintenanceStore.saveAnnotation(annotation)
            annotationsImported += 1
        }

        return ImportSummary(
            vehicles: vehiclesImported,
            maintenance: maintenanceImported,
            odometer: odometerImported,
            annotations: annotationsImported
        )
    }

    // MARK: - Encryption

    private static let saltSize = 32

    private static func deriveKey(passphrase: String, salt: Data) -> SymmetricKey {
        let passphraseData = Data(passphrase.utf8)
        let inputKey = SymmetricKey(data: SHA256.hash(data: passphraseData))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: salt,
            info: Data("cairn-backup-v1".utf8),
            outputByteCount: 32
        )
    }

    private static func encrypt(_ data: Data, passphrase: String) throws -> Data {
        var salt = Data(count: saltSize)
        salt.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, saltSize, $0.baseAddress!) }

        let key = deriveKey(passphrase: passphrase, salt: salt)
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else {
            throw PorterError.encryptionFailed
        }
        return salt + combined
    }

    private static func decrypt(_ data: Data, passphrase: String) throws -> Data {
        guard data.count > saltSize + 12 + 16 else {
            throw PorterError.invalidFile
        }
        let salt = data.prefix(saltSize)
        let sealedData = data.dropFirst(saltSize)

        let key = deriveKey(passphrase: passphrase, salt: salt)
        let box = try AES.GCM.SealedBox(combined: sealedData)
        do {
            return try AES.GCM.open(box, using: key)
        } catch {
            throw PorterError.wrongPassphrase
        }
    }
}

// MARK: - Types

struct ExportPayload: Codable {
    let version: Int
    let exportedAt: Date
    let vehicles: [Vehicle]
    let assignments: [VehicleAssignment]
    let maintenance: [MaintenanceEntry]
    let odometer: [OdometerCorrection]
    let annotations: [Annotation]
}

public struct ImportSummary: Sendable {
    public let vehicles: Int
    public let maintenance: Int
    public let odometer: Int
    public let annotations: Int

    public var total: Int { vehicles + maintenance + odometer + annotations }
}

public enum PorterError: LocalizedError {
    case encryptionFailed
    case invalidFile
    case wrongPassphrase

    public var errorDescription: String? {
        switch self {
        case .encryptionFailed: "Failed to encrypt data"
        case .invalidFile: "This file is not a valid Cairn backup"
        case .wrongPassphrase: "Wrong passphrase"
        }
    }
}
