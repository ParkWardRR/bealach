import Foundation

/// The reconciliation state of a recording across the SD card and iOS mirror. States come from
/// the reconciliation contract (reconciliation.md section 3).
public enum MirrorState: String, Codable, Sendable, Equatable {
    case pending
    case transferring
    case verified
    case missing
    case corrupt
    case deletedIntentionally = "deleted-intentionally"
}

/// A reconciliation snapshot scoped to a specific LIST response from the dongle. Verdicts are
/// always relative to this snapshot — a cached result is displayed with its timestamp and an
/// explicit stale indicator (reconciliation.md section 2).
public struct ReconciliationSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let computedAt: Date
    public let snapshotMarker: String
    public let dongleReachable: Bool
    public var entries: [ReconciliationEntry]

    public init(
        id: String = UUID().uuidString,
        computedAt: Date = Date(),
        snapshotMarker: String,
        dongleReachable: Bool,
        entries: [ReconciliationEntry] = []
    ) {
        self.id = id
        self.computedAt = computedAt
        self.snapshotMarker = snapshotMarker
        self.dongleReachable = dongleReachable
        self.entries = entries
    }

    public var verifiedCount: Int { entries.filter { $0.state == .verified }.count }
    public var pendingCount: Int { entries.filter { $0.state == .pending }.count }
    public var transferringCount: Int { entries.filter { $0.state == .transferring }.count }
    public var missingCount: Int { entries.filter { $0.state == .missing }.count }
    public var corruptCount: Int { entries.filter { $0.state == .corrupt }.count }

    public var isStale: Bool { !dongleReachable }
}

/// One recording's reconciliation state within a snapshot.
public struct ReconciliationEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let bundleID: String
    public let contentRoot: String
    public var state: MirrorState
    public var transferProgress: Double?
    public var explanation: String?

    public init(
        id: String = UUID().uuidString,
        bundleID: String,
        contentRoot: String,
        state: MirrorState,
        transferProgress: Double? = nil,
        explanation: String? = nil
    ) {
        self.id = id
        self.bundleID = bundleID
        self.contentRoot = contentRoot
        self.state = state
        self.transferProgress = transferProgress
        self.explanation = explanation
    }

    public var discrepancyExplanation: String {
        if let explanation { return explanation }
        switch state {
        case .verified:
            return "Mirrored and verified — content identities match the current snapshot."
        case .pending:
            return "Sealed on SD, not yet transferred to this phone."
        case .transferring:
            let pct = transferProgress.map { "\(Int($0 * 100))%" } ?? "unknown"
            return "Transfer interrupted at \(pct), resumable."
        case .missing:
            return "Known on one side but absent from the other."
        case .corrupt:
            return "Present but verification failed — this copy will not be trusted."
        case .deletedIntentionally:
            return "Removed from iPhone, kept on SD."
        }
    }
}
