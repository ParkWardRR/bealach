import BealachCore
import Foundation
import Testing

@Suite struct DeletionIntentTests {
    @Test func phaseProgression() {
        var intent = DeletionIntent(bundleID: "b1", contentRoot: "root1", store: .ios)
        #expect(intent.phase == .toDelete)
        #expect(!intent.isTerminal)

        intent.phase = .deleting
        #expect(!intent.isTerminal)

        intent.phase = .deleted
        #expect(intent.isTerminal)
    }

    @Test func failedIsTerminal() {
        var intent = DeletionIntent(bundleID: "b1", contentRoot: "root1", store: .sd)
        intent.phase = .failed
        #expect(intent.isTerminal)
    }

    @Test func tombstoneCreation() {
        let tombstone = Tombstone(bundleID: "b1", contentRoot: "root1")
        #expect(tombstone.actor == .owner)
        #expect(tombstone.bundleID == "b1")
    }

    @Test func reclaimEligibilityRequiresAllConditions() {
        #expect(ReclaimEligibility.isEligible(bundleID: "b1", mirrorState: .verified, hasSignedAck: true, hasTombstone: false))
        #expect(!ReclaimEligibility.isEligible(bundleID: "b1", mirrorState: .pending, hasSignedAck: true, hasTombstone: false))
        #expect(!ReclaimEligibility.isEligible(bundleID: "b1", mirrorState: .verified, hasSignedAck: false, hasTombstone: false))
        #expect(!ReclaimEligibility.isEligible(bundleID: "b1", mirrorState: .verified, hasSignedAck: true, hasTombstone: true))
        #expect(!ReclaimEligibility.isEligible(bundleID: "b1", mirrorState: .corrupt, hasSignedAck: true, hasTombstone: false))
        #expect(!ReclaimEligibility.isEligible(bundleID: "b1", mirrorState: .transferring, hasSignedAck: true, hasTombstone: false))
    }

    @Test func intentCodableRoundTrip() throws {
        let intent = DeletionIntent(bundleID: "b1", contentRoot: "root1", store: .ios, actor: .reclaimPolicy)
        let data = try JSONEncoder().encode(intent)
        let decoded = try JSONDecoder().decode(DeletionIntent.self, from: data)
        #expect(decoded == intent)
    }

    @Test func tombstoneCodableRoundTrip() throws {
        let tombstone = Tombstone(bundleID: "b1", contentRoot: "root1")
        let data = try JSONEncoder().encode(tombstone)
        let decoded = try JSONDecoder().decode(Tombstone.self, from: data)
        #expect(decoded == tombstone)
    }
}

@Suite struct ReconciliationSnapshotTests {
    @Test func countsByState() {
        let snapshot = ReconciliationSnapshot(
            snapshotMarker: "seq-42",
            dongleReachable: true,
            entries: [
                ReconciliationEntry(bundleID: "b1", contentRoot: "r1", state: .verified),
                ReconciliationEntry(bundleID: "b2", contentRoot: "r2", state: .verified),
                ReconciliationEntry(bundleID: "b3", contentRoot: "r3", state: .pending),
                ReconciliationEntry(bundleID: "b4", contentRoot: "r4", state: .transferring, transferProgress: 0.42),
                ReconciliationEntry(bundleID: "b5", contentRoot: "r5", state: .missing),
                ReconciliationEntry(bundleID: "b6", contentRoot: "r6", state: .corrupt, explanation: "manifest signature failed"),
            ]
        )
        #expect(snapshot.verifiedCount == 2)
        #expect(snapshot.pendingCount == 1)
        #expect(snapshot.transferringCount == 1)
        #expect(snapshot.missingCount == 1)
        #expect(snapshot.corruptCount == 1)
        #expect(!snapshot.isStale)
    }

    @Test func staleWhenDongleUnreachable() {
        let snapshot = ReconciliationSnapshot(snapshotMarker: "seq-1", dongleReachable: false)
        #expect(snapshot.isStale)
    }

    @Test func snapshotCodableRoundTrip() throws {
        let snapshot = ReconciliationSnapshot(
            snapshotMarker: "seq-99",
            dongleReachable: true,
            entries: [ReconciliationEntry(bundleID: "b1", contentRoot: "r1", state: .verified)]
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ReconciliationSnapshot.self, from: data)
        #expect(decoded == snapshot)
    }
}
