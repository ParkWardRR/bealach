import CairnCore
import CryptoKit
import Foundation
import GRDB
import os

public final class GRDBDriveStore: DriveStore, Sendable {
    private static let log = Logger(subsystem: "app.cairn.companion", category: "grdb-store")
    private static let maxDrivesPerVehicle = 200
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

    public func list() async throws -> [DriveSession] {
        try await db.dbPool.read { [decoder, db] dbConn in
            let rows = try Row.fetchAll(dbConn, sql: """
                SELECT encryptedData FROM drive_session ORDER BY startedAt DESC
            """)
            return rows.compactMap { row -> DriveSession? in
                guard let blob: Data = row["encryptedData"] else { return nil }
                guard let json = try? StoreEncryption.decrypt(blob, using: db.encryptionKey) else {
                    Self.log.error("failed to decrypt drive session")
                    return nil
                }
                return try? decoder.decode(DriveSession.self, from: json)
            }
        }
    }

    public func list(vehicleID: String) async throws -> [DriveSession] {
        try await db.dbPool.read { [decoder, db] dbConn in
            let rows = try Row.fetchAll(dbConn, sql: """
                SELECT encryptedData FROM drive_session WHERE vehicleID = ? ORDER BY startedAt DESC
            """, arguments: [vehicleID])
            return rows.compactMap { row -> DriveSession? in
                guard let blob: Data = row["encryptedData"] else { return nil }
                guard let json = try? StoreEncryption.decrypt(blob, using: db.encryptionKey) else { return nil }
                return try? decoder.decode(DriveSession.self, from: json)
            }
        }
    }

    public func get(_ id: UUID) async throws -> DriveSession? {
        try await db.dbPool.read { [decoder, db] dbConn in
            guard let row = try Row.fetchOne(dbConn, sql: """
                SELECT encryptedData FROM drive_session WHERE id = ?
            """, arguments: [id.uuidString]) else { return nil }
            guard let blob: Data = row["encryptedData"],
                  let json = try? StoreEncryption.decrypt(blob, using: db.encryptionKey) else { return nil }
            return try? decoder.decode(DriveSession.self, from: json)
        }
    }

    public func save(_ session: DriveSession) async throws {
        let json = try encoder.encode(session)
        let encrypted = try StoreEncryption.encrypt(json, using: db.encryptionKey)

        try await db.dbPool.write { dbConn in
            try dbConn.execute(sql: """
                INSERT OR REPLACE INTO drive_session
                    (id, vehicleID, deviceID, lifecycle, startedAt, closedAt, schemaVersion, encryptedData)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                session.id.uuidString,
                session.vehicleID,
                session.deviceID,
                session.lifecycle.rawValue,
                session.startedAt,
                session.closedAt,
                session.schemaVersion,
                encrypted,
            ])
        }
    }

    public func delete(_ id: UUID) async throws {
        try await db.dbPool.write { dbConn in
            try dbConn.execute(sql: "DELETE FROM drive_session WHERE id = ?",
                               arguments: [id.uuidString])
        }
    }

    public func deleteAll() async throws {
        try await db.dbPool.write { dbConn in
            try dbConn.execute(sql: "DELETE FROM drive_session")
        }
    }

    public func applyRetention(vehicleID: String? = nil) async throws {
        try await db.dbPool.write { dbConn in
            let where_clause = vehicleID.map { "WHERE vehicleID = '\($0)'" } ?? ""
            let ids = try String.fetchAll(dbConn, sql: """
                SELECT id FROM drive_session \(where_clause)
                ORDER BY startedAt DESC
                LIMIT -1 OFFSET \(Self.maxDrivesPerVehicle)
            """)
            guard !ids.isEmpty else { return }
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            try dbConn.execute(
                sql: "DELETE FROM drive_session WHERE id IN (\(placeholders)) AND lifecycle = 'closed'",
                arguments: StatementArguments(ids)
            )
        }
    }
}
