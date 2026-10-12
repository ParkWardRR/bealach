import CairnCore
import CryptoKit
import Foundation
import GRDB
import os

public final class CairnDatabase: Sendable {
    private static let log = Logger(subsystem: "app.cairn.companion", category: "db")
    let dbPool: DatabasePool
    let encryptionKey: SymmetricKey

    public init(path: URL? = nil) throws {
        let dir = path ?? Self.defaultPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let dbFile = dir.appendingPathComponent("cairn.sqlite")
        Self.setFileProtection(dbFile)
        Self.excludeFromBackup(dir)

        var config = Configuration()
        #if DEBUG
        config.prepareDatabase { db in
            db.trace { Self.log.debug("\($0)") }
        }
        #endif

        dbPool = try DatabasePool(path: dbFile.path, configuration: config)
        encryptionKey = try StoreEncryption.loadOrCreateKey()

        try migrator.migrate(dbPool)
        Self.log.notice("database ready at \(dbFile.path, privacy: .private)")
    }

    private static func defaultPath() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("cairn-db", isDirectory: true)
    }

    private static func setFileProtection(_ url: URL) {
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }

    private static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    // MARK: - Migrations

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1-create-tables") { db in
            try db.create(table: "drive_session") { t in
                t.primaryKey("id", .text).notNull()
                t.column("vehicleID", .text)
                t.column("deviceID", .text)
                t.column("lifecycle", .text).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("closedAt", .datetime)
                t.column("schemaVersion", .integer).notNull()
                t.column("encryptedData", .blob).notNull()
            }

            try db.create(table: "vehicle") { t in
                t.primaryKey("id", .text).notNull()
                t.column("year", .integer).notNull()
                t.column("make", .text).notNull()
                t.column("model", .text).notNull()
                t.column("engineCode", .text)
                t.column("isArchived", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "vehicleAssignment") { t in
                t.primaryKey("dongleID", .text).notNull()
                t.column("vehicleID", .text).notNull()
                    .references("vehicle", onDelete: .cascade)
            }

            try db.create(table: "syncState") { t in
                t.primaryKey("id", .text).notNull()
                t.column("vehicleID", .text)
                t.column("serverInstance", .text).notNull()
                t.column("cursor", .text)
                t.column("lastSuccessAt", .datetime)
                t.column("retryCount", .integer).notNull().defaults(to: 0)
                t.column("lastError", .text)
            }

            try db.create(table: "outbox") { t in
                t.autoIncrementedPrimaryKey("rowid")
                t.column("id", .text).notNull().unique()
                t.column("vehicleID", .text)
                t.column("kind", .text).notNull()
                t.column("encryptedPayload", .blob).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("lastAttemptAt", .datetime)
                t.column("lastError", .text)
            }

            try db.create(table: "tripSummary") { t in
                t.primaryKey("id", .text).notNull()
                t.column("vehicleID", .text)
                t.column("encryptedData", .blob).notNull()
                t.column("snapshotAt", .datetime).notNull()
            }

            try db.create(table: "annotation") { t in
                t.primaryKey("id", .text).notNull()
                t.column("vehicleID", .text)
                t.column("targetID", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("encryptedData", .blob).notNull()
                t.column("revision", .integer).notNull().defaults(to: 1)
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "maintenanceEntry") { t in
                t.primaryKey("id", .text).notNull()
                t.column("vehicleID", .text).notNull()
                t.column("category", .text).notNull()
                t.column("encryptedData", .blob).notNull()
                t.column("performedAt", .datetime).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "odometerCorrection") { t in
                t.primaryKey("id", .text).notNull()
                t.column("vehicleID", .text).notNull()
                t.column("odometerKm", .integer).notNull()
                t.column("recordedAt", .datetime).notNull()
                t.column("revision", .integer).notNull().defaults(to: 1)
            }

            try db.create(table: "enrolment") { t in
                t.primaryKey("id", .text).notNull()
                t.column("clientID", .text).notNull()
                t.column("role", .text).notNull()
                t.column("state", .text).notNull()
                t.column("scope", .text).notNull()
                t.column("instanceID", .text)
                t.column("spkiSHA256", .text)
                t.column("enrolledAt", .datetime)
            }

            try db.create(index: "drive_session_vehicleID", on: "drive_session", columns: ["vehicleID"])
            try db.create(index: "outbox_kind", on: "outbox", columns: ["kind", "createdAt"])
            try db.create(index: "annotation_target", on: "annotation", columns: ["targetID"])
            try db.create(index: "maintenanceEntry_vehicle", on: "maintenanceEntry", columns: ["vehicleID", "performedAt"])
        }

        return migrator
    }
}
