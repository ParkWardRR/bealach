import BealachCore
@testable import BealachRuntime
import Foundation
import Testing

@Suite struct GRDBReconciliationStoreTests {
    private func makeStore() throws -> (GRDBReconciliationStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bealach-test-\(UUID().uuidString)", isDirectory: true)
        let db = try BealachDatabase(path: tmp)
        return (GRDBReconciliationStore(db: db), tmp)
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func saveAndLoadSnapshot() async throws {
        let (store, dir) = try makeStore()
        defer { cleanup(dir) }

        let snapshot = ReconciliationSnapshot(
            snapshotMarker: "seq-1",
            dongleReachable: true,
            entries: [
                ReconciliationEntry(bundleID: "b1", contentRoot: "r1", state: .verified),
                ReconciliationEntry(bundleID: "b2", contentRoot: "r2", state: .pending),
            ]
        )
        try await store.saveSnapshot(snapshot)

        let loaded = try await store.latestSnapshot()
        #expect(loaded != nil)
        #expect(loaded?.snapshotMarker == "seq-1")
        #expect(loaded?.entries.count == 2)
        #expect(loaded?.verifiedCount == 1)
        #expect(loaded?.pendingCount == 1)
    }

    @Test func latestSnapshotReturnsNewest() async throws {
        let (store, dir) = try makeStore()
        defer { cleanup(dir) }

        let old = ReconciliationSnapshot(
            computedAt: Date(timeIntervalSince1970: 1000),
            snapshotMarker: "seq-1",
            dongleReachable: true,
            entries: [ReconciliationEntry(bundleID: "b1", contentRoot: "r1", state: .pending)]
        )
        let newer = ReconciliationSnapshot(
            computedAt: Date(timeIntervalSince1970: 2000),
            snapshotMarker: "seq-2",
            dongleReachable: false,
            entries: [ReconciliationEntry(bundleID: "b1", contentRoot: "r1", state: .verified)]
        )
        try await store.saveSnapshot(old)
        try await store.saveSnapshot(newer)

        let loaded = try await store.latestSnapshot()
        #expect(loaded?.snapshotMarker == "seq-2")
        #expect(loaded?.isStale == true)
        #expect(loaded?.verifiedCount == 1)
    }

    @Test func deletionIntentLifecycle() async throws {
        let (store, dir) = try makeStore()
        defer { cleanup(dir) }

        let intent = DeletionIntent(bundleID: "b1", contentRoot: "r1", store: .ios)
        try await store.createDeletionIntent(intent)

        var active = try await store.activeDeletionIntents()
        #expect(active.count == 1)
        #expect(active[0].phase == .toDelete)

        try await store.updateDeletionPhase(id: intent.id, phase: .deleting)
        active = try await store.activeDeletionIntents()
        #expect(active.count == 1)
        #expect(active[0].phase == .deleting)

        try await store.updateDeletionPhase(id: intent.id, phase: .deleted, completedAt: Date())
        active = try await store.activeDeletionIntents()
        #expect(active.isEmpty)

        let all = try await store.allDeletionIntents()
        #expect(all.count == 1)
        #expect(all[0].phase == .deleted)
        #expect(all[0].completedAt != nil)
    }

    @Test func tombstoneCreateAndRemove() async throws {
        let (store, dir) = try makeStore()
        defer { cleanup(dir) }

        let tombstone = Tombstone(bundleID: "b1", contentRoot: "r1")
        try await store.createTombstone(tombstone)
        #expect(try await store.hasTombstone(bundleID: "b1"))

        let all = try await store.allTombstones()
        #expect(all.count == 1)
        #expect(all[0].bundleID == "b1")

        try await store.removeTombstone(bundleID: "b1")
        #expect(try await !store.hasTombstone(bundleID: "b1"))
        #expect(try await store.allTombstones().isEmpty)
    }

    @Test func deletionPipelineEndToEnd() async throws {
        let (store, dir) = try makeStore()
        defer { cleanup(dir) }

        let snapshot = ReconciliationSnapshot(
            snapshotMarker: "seq-1",
            dongleReachable: true,
            entries: [
                ReconciliationEntry(bundleID: "b1", contentRoot: "r1", state: .verified),
                ReconciliationEntry(bundleID: "b2", contentRoot: "r2", state: .verified),
            ]
        )
        try await store.saveSnapshot(snapshot)

        let intent = DeletionIntent(bundleID: "b1", contentRoot: "r1", store: .ios)
        try await store.createDeletionIntent(intent)
        try await store.updateDeletionPhase(id: intent.id, phase: .deleted, completedAt: Date())
        try await store.createTombstone(Tombstone(bundleID: "b1", contentRoot: "r1"))

        #expect(try await store.hasTombstone(bundleID: "b1"))
        #expect(try await !store.hasTombstone(bundleID: "b2"))
        #expect(try await store.activeDeletionIntents().isEmpty)
        #expect(try await store.allTombstones().count == 1)

        try await store.removeTombstone(bundleID: "b1")
        #expect(try await !store.hasTombstone(bundleID: "b1"))
    }

    @Test func emptyStoreReturnsNil() async throws {
        let (store, dir) = try makeStore()
        defer { cleanup(dir) }

        #expect(try await store.latestSnapshot() == nil)
        #expect(try await store.activeDeletionIntents().isEmpty)
        #expect(try await store.allDeletionIntents().isEmpty)
        #expect(try await store.allTombstones().isEmpty)
    }
}
