import CairnCore
import CryptoKit
import Foundation
import GRDB

public final class GRDBMaintenanceStore: MaintenanceStore, Sendable {
    private let db: CairnDatabase

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(db: CairnDatabase) {
        self.db = db
    }

    // MARK: - Maintenance entries

    public func listEntries(vehicleID: String) async throws -> [MaintenanceEntry] {
        try await db.dbPool.read { [decoder, db] dbConn in
            let rows = try Row.fetchAll(dbConn, sql: """
                SELECT encryptedData FROM maintenanceEntry
                WHERE vehicleID = ? ORDER BY performedAt DESC
            """, arguments: [vehicleID])
            return rows.compactMap { row -> MaintenanceEntry? in
                guard let blob: Data = row["encryptedData"],
                      let json = try? StoreEncryption.decrypt(blob, using: db.encryptionKey) else { return nil }
                return try? decoder.decode(MaintenanceEntry.self, from: json)
            }
        }
    }

    public func saveEntry(_ entry: MaintenanceEntry) async throws {
        let json = try encoder.encode(entry)
        let encrypted = try StoreEncryption.encrypt(json, using: db.encryptionKey)

        try await db.dbPool.write { dbConn in
            try dbConn.execute(sql: """
                INSERT OR REPLACE INTO maintenanceEntry
                    (id, vehicleID, category, encryptedData, performedAt, createdAt)
                VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [
                entry.id,
                entry.vehicleID,
                entry.category.rawValue,
                encrypted,
                entry.performedAt,
                entry.createdAt,
            ])
        }
    }

    public func deleteEntry(_ id: String) async throws {
        try await db.dbPool.write { dbConn in
            try dbConn.execute(sql: "DELETE FROM maintenanceEntry WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Odometer corrections

    public func listOdometerCorrections(vehicleID: String) async throws -> [OdometerCorrection] {
        try await db.dbPool.read { dbConn in
            try Row.fetchAll(dbConn, sql: """
                SELECT id, vehicleID, odometerKm, recordedAt, revision
                FROM odometerCorrection WHERE vehicleID = ? ORDER BY recordedAt DESC
            """, arguments: [vehicleID]).map { row in
                OdometerCorrection(
                    id: row["id"],
                    vehicleID: row["vehicleID"],
                    odometerKm: row["odometerKm"],
                    recordedAt: row["recordedAt"],
                    revision: row["revision"]
                )
            }
        }
    }

    public func saveOdometerCorrection(_ correction: OdometerCorrection) async throws {
        try await db.dbPool.write { dbConn in
            try dbConn.execute(sql: """
                INSERT OR REPLACE INTO odometerCorrection
                    (id, vehicleID, odometerKm, recordedAt, revision)
                VALUES (?, ?, ?, ?, ?)
            """, arguments: [
                correction.id,
                correction.vehicleID,
                correction.odometerKm,
                correction.recordedAt,
                correction.revision,
            ])
        }
    }

    public func deleteOdometerCorrection(_ id: String) async throws {
        try await db.dbPool.write { dbConn in
            try dbConn.execute(sql: "DELETE FROM odometerCorrection WHERE id = ?", arguments: [id])
        }
    }

    public func latestOdometer(vehicleID: String) async throws -> OdometerCorrection? {
        try await db.dbPool.read { dbConn in
            guard let row = try Row.fetchOne(dbConn, sql: """
                SELECT id, vehicleID, odometerKm, recordedAt, revision
                FROM odometerCorrection WHERE vehicleID = ? ORDER BY recordedAt DESC LIMIT 1
            """, arguments: [vehicleID]) else { return nil }
            return OdometerCorrection(
                id: row["id"],
                vehicleID: row["vehicleID"],
                odometerKm: row["odometerKm"],
                recordedAt: row["recordedAt"],
                revision: row["revision"]
            )
        }
    }

    // MARK: - Annotations

    public func annotations(forTarget targetID: String) async throws -> [Annotation] {
        try await db.dbPool.read { [decoder, db] dbConn in
            let rows = try Row.fetchAll(dbConn, sql: """
                SELECT encryptedData FROM annotation WHERE targetID = ? ORDER BY updatedAt DESC
            """, arguments: [targetID])
            return rows.compactMap { row -> Annotation? in
                guard let blob: Data = row["encryptedData"],
                      let json = try? StoreEncryption.decrypt(blob, using: db.encryptionKey) else { return nil }
                return try? decoder.decode(Annotation.self, from: json)
            }
        }
    }

    public func listAnnotations(vehicleID: String?) async throws -> [Annotation] {
        try await db.dbPool.read { [decoder, db] dbConn in
            let sql: String
            let args: StatementArguments
            if let vehicleID {
                sql = "SELECT encryptedData FROM annotation WHERE vehicleID = ? ORDER BY updatedAt DESC"
                args = [vehicleID]
            } else {
                sql = "SELECT encryptedData FROM annotation ORDER BY updatedAt DESC"
                args = []
            }
            let rows = try Row.fetchAll(dbConn, sql: sql, arguments: args)
            return rows.compactMap { row -> Annotation? in
                guard let blob: Data = row["encryptedData"],
                      let json = try? StoreEncryption.decrypt(blob, using: db.encryptionKey) else { return nil }
                return try? decoder.decode(Annotation.self, from: json)
            }
        }
    }

    public func saveAnnotation(_ annotation: Annotation) async throws {
        let json = try encoder.encode(annotation)
        let encrypted = try StoreEncryption.encrypt(json, using: db.encryptionKey)

        try await db.dbPool.write { dbConn in
            try dbConn.execute(sql: """
                INSERT OR REPLACE INTO annotation
                    (id, vehicleID, targetID, kind, encryptedData, revision, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                annotation.id,
                annotation.vehicleID,
                annotation.targetID,
                annotation.kind.rawValue,
                encrypted,
                annotation.revision,
                annotation.updatedAt,
            ])
        }
    }

    public func deleteAnnotation(_ id: String) async throws {
        try await db.dbPool.write { dbConn in
            try dbConn.execute(sql: "DELETE FROM annotation WHERE id = ?", arguments: [id])
        }
    }
}
