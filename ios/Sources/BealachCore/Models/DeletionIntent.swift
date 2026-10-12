import Foundation

/// Durable deletion intent per deletion.md section 5. Deletions progress through states so a
/// crash or device reset mid-deletion leaves consistent, explainable state.
public struct DeletionIntent: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let bundleID: String
    public let contentRoot: String
    public let store: Store
    public var phase: Phase
    public let requestedAt: Date
    public var completedAt: Date?
    public let actor: Actor

    public init(
        id: String = UUID().uuidString,
        bundleID: String,
        contentRoot: String,
        store: Store,
        phase: Phase = .toDelete,
        requestedAt: Date = Date(),
        completedAt: Date? = nil,
        actor: Actor = .owner
    ) {
        self.id = id
        self.bundleID = bundleID
        self.contentRoot = contentRoot
        self.store = store
        self.phase = phase
        self.requestedAt = requestedAt
        self.completedAt = completedAt
        self.actor = actor
    }

    public var isTerminal: Bool { phase == .deleted || phase == .failed }

    public enum Store: String, Codable, Sendable, Equatable {
        case ios
        case sd
    }

    public enum Phase: String, Codable, Sendable, Equatable {
        case toDelete = "to-delete"
        case deleting
        case deleted
        case failed
    }

    public enum Actor: String, Codable, Sendable, Equatable {
        case owner
        case reclaimPolicy = "reclaim-policy"
    }
}

/// A tombstone left after an iOS copy is deleted. Blocks automatic re-download from the dongle
/// until the user explicitly clears it with "fetch again" (deletion.md section 4).
public struct Tombstone: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let bundleID: String
    public let contentRoot: String
    public let deletedAt: Date
    public let actor: DeletionIntent.Actor

    public init(
        id: String = UUID().uuidString,
        bundleID: String,
        contentRoot: String,
        deletedAt: Date = Date(),
        actor: DeletionIntent.Actor = .owner
    ) {
        self.id = id
        self.bundleID = bundleID
        self.contentRoot = contentRoot
        self.deletedAt = deletedAt
        self.actor = actor
    }
}

/// SD reclaim eligibility check per deletion.md section 1.2. A recording is reclaimable only
/// when ALL of these are true:
/// - A signed owner-phone acknowledgement names its exact content
/// - The phone-side copy is verified
/// - No tombstone blocks it
public enum ReclaimEligibility {
    public static func isEligible(
        bundleID: String,
        mirrorState: MirrorState,
        hasSignedAck: Bool,
        hasTombstone: Bool
    ) -> Bool {
        mirrorState == .verified && hasSignedAck && !hasTombstone
    }
}
