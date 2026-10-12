import BealachCore
import Foundation
import GRDB
import os

public final class GRDBReconciliationStore: Sendable {
    private static let log = Logger(subsystem: "app.bealach", category: "reconciliation-store")
    private let db: BealachDatabase

    public init(db: BealachDatabase) {
        self.db = db
    }

    // MARK: - Snapshots

    public func saveSnapshot(_ snapshot: ReconciliationSnapshot) async throws {
        try await db.dbPool.write { dbConn in
            try dbConn.execute(sql: """
                INSERT OR REPLACE INTO reconciliationSnapshot (id, computedAt, snapshotMarker, dongleReachable)
                VALUES (?, ?, ?, ?)
            """, arguments: [snapshot.id, snapshot.computedAt, snapshot.snapshotMarker, snapshot.dongleReachable])

            for entry in snapshot.entries {
                try dbConn.execute(sql: """
                    INSERT OR REPLACE INTO reconciliationEntry (id, snapshotID, bundleID, contentRoot, state, transferProgress, explanation)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [entry.id, snapshot.id, entry.bundleID, entry.contentRoot, entry.state.rawValue, entry.transferProgress, entry.explanation])
            }
        }
    }

    public func latestSnapshot() async throws -> ReconciliationSnapshot? {
        try await db.dbPool.read { dbConn in
            guard let row = try Row.fetchOne(dbConn, sql: """
                SELECT id, computedAt, snapshotMarker, dongleReachable
                FROM reconciliationSnapshot ORDER BY computedAt DESC LIMIT 1
            """) else { return nil }

            let snapshotID: String = row["id"]
            let entries = try Row.fetchAll(dbConn, sql: """
                SELECT id, bundleID, contentRoot, state, transferProgress, explanation
                FROM reconciliationEntry WHERE snapshotID = ?
            """, arguments: [snapshotID])

            return ReconciliationSnapshot(
                id: snapshotID,
                computedAt: row["computedAt"],
                snapshotMarker: row["snapshotMarker"],
                dongleReachable: row["dongleReachable"],
                entries: entries.compactMap { e in
                    guard let state = MirrorState(rawValue: e["state"]) else { return nil }
                    return ReconciliationEntry(
                        id: e["id"],
                        bundleID: e["bundleID"],
                        contentRoot: e["contentRoot"],
                        state: state,
                        transferProgress: e["transferProgress"],
                        explanation: e["explanation"]
                    )
                }
            )
        }
    }

    // MARK: - Deletion Intents

    public func createDeletionIntent(_ intent: DeletionIntent) async throws {
        try await db.dbPool.write { dbConn in
            try dbConn.execute(sql: """
                INSERT INTO deletionIntent (id, bundleID, contentRoot, store, phase, requestedAt, completedAt, actor)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [intent.id, intent.bundleID, intent.contentRoot, intent.store.rawValue, intent.phase.rawValue, intent.requestedAt, intent.completedAt, intent.actor.rawValue])
        }
    }

    public func updateDeletionPhase(id: String, phase: DeletionIntent.Phase, completedAt: Date? = nil) async throws {
        try await db.dbPool.write { dbConn in
            try dbConn.execute(sql: """
                UPDATE deletionIntent SET phase = ?, completedAt = ? WHERE id = ?
            """, arguments: [phase.rawValue, completedAt, id])
        }
    }

    public func activeDeletionIntents() async throws -> [DeletionIntent] {
        try await db.dbPool.read { dbConn in
            let rows = try Row.fetchAll(dbConn, sql: """
                SELECT id, bundleID, contentRoot, store, phase, requestedAt, completedAt, actor
                FROM deletionIntent WHERE phase NOT IN ('deleted', 'failed')
                ORDER BY requestedAt DESC
            """)
            return rows.compactMap(Self.intentFromRow)
        }
    }

    public func allDeletionIntents() async throws -> [DeletionIntent] {
        try await db.dbPool.read { dbConn in
            let rows = try Row.fetchAll(dbConn, sql: """
                SELECT id, bundleID, contentRoot, store, phase, requestedAt, completedAt, actor
                FROM deletionIntent ORDER BY requestedAt DESC
            """)
            return rows.compactMap(Self.intentFromRow)
        }
    }

    // MARK: - Tombstones

    public func createTombstone(_ tombstone: Tombstone) async throws {
        try await db.dbPool.write { dbConn in
            try dbConn.execute(sql: """
                INSERT OR REPLACE INTO tombstone (id, bundleID, contentRoot, deletedAt, actor)
                VALUES (?, ?, ?, ?, ?)
            """, arguments: [tombstone.id, tombstone.bundleID, tombstone.contentRoot, tombstone.deletedAt, tombstone.actor.rawValue])
        }
    }

    public func removeTombstone(bundleID: String) async throws {
        try await db.dbPool.write { dbConn in
            try dbConn.execute(sql: "DELETE FROM tombstone WHERE bundleID = ?", arguments: [bundleID])
        }
    }

    public func allTombstones() async throws -> [Tombstone] {
        try await db.dbPool.read { dbConn in
            let rows = try Row.fetchAll(dbConn, sql: """
                SELECT id, bundleID, contentRoot, deletedAt, actor FROM tombstone ORDER BY deletedAt DESC
            """)
            return rows.compactMap { row in
                guard let actor = DeletionIntent.Actor(rawValue: row["actor"]) else { return nil }
                return Tombstone(
                    id: row["id"],
                    bundleID: row["bundleID"],
                    contentRoot: row["contentRoot"],
                    deletedAt: row["deletedAt"],
                    actor: actor
                )
            }
        }
    }

    public func hasTombstone(bundleID: String) async throws -> Bool {
        try await db.dbPool.read { dbConn in
            let count = try Int.fetchOne(dbConn, sql: "SELECT COUNT(*) FROM tombstone WHERE bundleID = ?", arguments: [bundleID])
            return (count ?? 0) > 0
        }
    }

    // MARK: - Helpers

    private static func intentFromRow(_ row: Row) -> DeletionIntent? {
        guard let store = DeletionIntent.Store(rawValue: row["store"]),
              let phase = DeletionIntent.Phase(rawValue: row["phase"]),
              let actor = DeletionIntent.Actor(rawValue: row["actor"]) else { return nil }
        return DeletionIntent(
            id: row["id"],
            bundleID: row["bundleID"],
            contentRoot: row["contentRoot"],
            store: store,
            phase: phase,
            requestedAt: row["requestedAt"],
            completedAt: row["completedAt"],
            actor: actor
        )
    }
}
