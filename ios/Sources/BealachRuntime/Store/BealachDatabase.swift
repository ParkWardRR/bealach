// Provenance: cairn-ios-companion-app @ a7d02d8, Sources/CairnRuntime/Store/BealachDatabase.swift
// Renamed Cairn* → Bealach* for Bealach.

import BealachCore
import CryptoKit
import Foundation
import GRDB
import os

public final class BealachDatabase: Sendable {
    private static let log = Logger(subsystem: "app.bealach", category: "db")
    let dbPool: DatabasePool
    let encryptionKey: SymmetricKey

    public init(path: URL? = nil) throws {
        let dir = path ?? Self.defaultPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let dbFile = dir.appendingPathComponent("bealach.sqlite")
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
            .appendingPathComponent("bealach-db", isDirectory: true)
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
                t.column("vin", .text)
                t.column("isArchived", .boolean).notNull().defaults(to: false)
                t.column("category", .text).notNull().defaults(to: "personal")
                t.column("identificationSource", .text).notNull().defaults(to: "manual")
                t.column("identificationConfidence", .text).notNull().defaults(to: "confirmed")
            }

            try db.create(table: "vehicleAssignment") { t in
                t.primaryKey("id", .text).notNull()
                t.column("dongleID", .text).notNull()
                t.column("vehicleID", .text).notNull()
                    .references("vehicle", onDelete: .cascade)
                t.column("assignedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
                t.column("source", .text).notNull().defaults(to: "manual")
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
                t.column("deviceID", .blob).notNull()
                t.column("fingerprint", .text).notNull()
                t.column("ownerKeyHex", .text).notNull()
                t.column("state", .text).notNull()
                t.column("enrolledAt", .datetime).notNull()
            }

            try db.create(index: "drive_session_vehicleID", on: "drive_session", columns: ["vehicleID"])
            try db.create(index: "annotation_target", on: "annotation", columns: ["targetID"])
            try db.create(index: "maintenanceEntry_vehicle", on: "maintenanceEntry", columns: ["vehicleID", "performedAt"])
        }

        migrator.registerMigration("v2-reconciliation-deletion") { db in
            try db.create(table: "reconciliationSnapshot") { t in
                t.primaryKey("id", .text).notNull()
                t.column("computedAt", .datetime).notNull()
                t.column("snapshotMarker", .text).notNull()
                t.column("dongleReachable", .boolean).notNull()
            }

            try db.create(table: "reconciliationEntry") { t in
                t.primaryKey("id", .text).notNull()
                t.column("snapshotID", .text).notNull()
                    .references("reconciliationSnapshot", onDelete: .cascade)
                t.column("bundleID", .text).notNull()
                t.column("contentRoot", .text).notNull()
                t.column("state", .text).notNull()
                t.column("transferProgress", .double)
                t.column("explanation", .text)
            }

            try db.create(table: "deletionIntent") { t in
                t.primaryKey("id", .text).notNull()
                t.column("bundleID", .text).notNull()
                t.column("contentRoot", .text).notNull()
                t.column("store", .text).notNull()
                t.column("phase", .text).notNull()
                t.column("requestedAt", .datetime).notNull()
                t.column("completedAt", .datetime)
                t.column("actor", .text).notNull()
            }

            try db.create(table: "tombstone") { t in
                t.primaryKey("id", .text).notNull()
                t.column("bundleID", .text).notNull()
                t.column("contentRoot", .text).notNull()
                t.column("deletedAt", .datetime).notNull()
                t.column("actor", .text).notNull()
            }

            try db.create(index: "reconciliationEntry_snapshot", on: "reconciliationEntry", columns: ["snapshotID"])
            try db.create(index: "deletionIntent_bundle", on: "deletionIntent", columns: ["bundleID"])
            try db.create(index: "tombstone_bundle", on: "tombstone", columns: ["bundleID"])
        }

        migrator.registerMigration("v3-mirror-entry") { db in
            try db.create(table: "mirrorEntry") { t in
                t.primaryKey("bundleID", .text).notNull()
                t.column("contentRoot", .text).notNull()
                t.column("manifestHash", .text).notNull()
                t.column("memberCount", .integer).notNull()
                t.column("totalBytes", .integer).notNull()
                t.column("verifiedAt", .datetime).notNull()
            }
        }

        return migrator
    }
}
