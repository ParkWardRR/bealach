import Foundation

// MARK: - Lifecycle

/// A phone-observed session. This is NOT a trip — the phone cannot know engine start/stop.
/// BLE readiness starts a session; the session ends when the link has been down longer than
/// `DriveSegmenter.gapThreshold` or when the user disarms.
public struct DriveSession: Codable, Identifiable, Sendable, Equatable {
    public static let schemaVersion = 2

    public let id: UUID
    public let deviceID: String?
    public var vehicleID: String?
    public var schemaVersion: Int = Self.schemaVersion
    public var lifecycle: Lifecycle
    public var startedAt: Date
    public var lastObservedAt: Date
    public var closedAt: Date?
    public var closeReason: CloseReason?

    // MARK: Counter epochs

    /// Accumulated counters across all connection epochs in this session.
    public var counters: Counters
    /// Baselines snapshotted at the start of each BLE connection, so counter deltas are meaningful
    /// even when the dongle reboots or the phone reconnects.
    public var epochs: [CounterEpoch]

    // MARK: Streaming

    /// Accumulated seconds where the dongle acknowledged acceptance (COMPANION_STATUS within 3 s).
    public var streamingSeconds: TimeInterval
    /// Total seconds where the phone could observe the link (connected time, excluding gaps and suspension).
    public var observedSeconds: TimeInterval

    // MARK: Link events

    public var events: [LinkEvent]
    public var reconnects: Int

    // MARK: Track

    public var track: [TrackPoint]
    public var trackSegments: [TrackSegment]

    // MARK: Signal presence

    /// True once any `OBD_LIVE` notification arrived during this session.
    public var obdReceived: Bool
    /// True once `DEVICE_STATUS` reported `tripPhase == .driving` during this session.
    public var deviceReportedDriving: Bool

    // MARK: Server reconciliation

    public var serverState: ServerState
    public var remoteTripID: String?

    public init(
        id: UUID = UUID(),
        deviceID: String? = nil,
        vehicleID: String? = nil,
        startedAt: Date = Date()
    ) {
        self.id = id
        self.deviceID = deviceID
        self.vehicleID = vehicleID
        self.lifecycle = .active
        self.startedAt = startedAt
        self.lastObservedAt = startedAt
        self.closedAt = nil
        self.closeReason = nil
        self.counters = Counters()
        self.epochs = []
        self.streamingSeconds = 0
        self.observedSeconds = 0
        self.events = []
        self.reconnects = 0
        self.track = []
        self.trackSegments = [TrackSegment(startIndex: 0, startedAt: startedAt)]
        self.obdReceived = false
        self.deviceReportedDriving = false
        self.serverState = .unknown
    }
}

// MARK: - Enums

public extension DriveSession {
    enum Lifecycle: String, Codable, Sendable, Equatable {
        case active
        case gapPending
        case interrupted
        case closed
    }

    enum CloseReason: String, Codable, Sendable, Equatable {
        case disarmed
        case linkGap
        case retryExhausted
        case bluetoothOff
        case permissionRevoked
        case appTerminatedDuringGap
    }

    enum ServerState: String, Codable, Sendable, Equatable {
        case unknown
        case pendingSync
        case uploaded
        case consumed
    }
}

// MARK: - Counters

public extension DriveSession {
    struct Counters: Codable, Sendable, Equatable {
        public var sent: Int = 0
        public var writeFailures: Int = 0
        public var accepted: Int = 0
        public var rejected: Int = 0
        public var queueDrops: Int = 0

        public init() {}

        /// What the phone wrote but the dongle has not reported on.
        /// Negative values (dongle reported more than we sent, e.g. after a reconnect) are clamped to zero.
        public var counterGap: Int {
            max(0, sent - accepted - rejected)
        }

        public mutating func accumulate(from epoch: CounterEpoch, status: CompanionStatus?) {
            guard let status else { return }
            let deltaAccepted = Int(status.acceptedCount) - epoch.baselineAccepted
            let deltaRejected = Int(status.rejectedCount) - epoch.baselineRejected
            let deltaDrops = Int(status.queueDropCount) - epoch.baselineQueueDrops
            accepted = epoch.priorAccepted + max(0, deltaAccepted)
            rejected = epoch.priorRejected + max(0, deltaRejected)
            queueDrops = epoch.priorQueueDrops + max(0, deltaDrops)
        }
    }
}

// MARK: - Counter epoch

/// Snapshot of dongle-side counters at the start of a BLE connection. The dongle resets its counters
/// on every connect, so deltas are only valid within one epoch.
public struct CounterEpoch: Codable, Sendable, Equatable {
    public let connectionID: UUID
    public let startedAt: Date
    public var baselineAccepted: Int
    public var baselineRejected: Int
    public var baselineQueueDrops: Int
    /// Accumulated totals from all previous epochs, so the current epoch's delta can be added.
    public var priorAccepted: Int
    public var priorRejected: Int
    public var priorQueueDrops: Int

    public init(
        connectionID: UUID = UUID(),
        startedAt: Date = Date(),
        priorAccepted: Int = 0,
        priorRejected: Int = 0,
        priorQueueDrops: Int = 0
    ) {
        self.connectionID = connectionID
        self.startedAt = startedAt
        self.baselineAccepted = 0
        self.baselineRejected = 0
        self.baselineQueueDrops = 0
        self.priorAccepted = priorAccepted
        self.priorRejected = priorRejected
        self.priorQueueDrops = priorQueueDrops
    }
}

// MARK: - Track

public struct TrackPoint: Codable, Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double
    public let horizontalAccuracy: Double
    public let speed: Double
    public let timestamp: Date

    public init(fix: PhoneGNSSFix) {
        self.latitude = fix.latitude
        self.longitude = fix.longitude
        self.altitude = fix.ellipsoidalAltitude
        self.horizontalAccuracy = fix.horizontalAccuracy
        self.speed = fix.speed
        self.timestamp = fix.timestamp
    }

    public static let maxAccuracy: Double = 50
}

/// A contiguous run of track points. A new segment starts after a gap (reconnect, suspension).
/// The map draws segments independently so it doesn't connect across gaps.
public struct TrackSegment: Codable, Sendable, Equatable {
    public let startIndex: Int
    public var endIndex: Int?
    public let startedAt: Date

    public init(startIndex: Int, startedAt: Date) {
        self.startIndex = startIndex
        self.startedAt = startedAt
        self.endIndex = nil
    }
}

// MARK: - Computed

public extension DriveSession {
    var duration: TimeInterval {
        let end = closedAt ?? lastObservedAt
        return end.timeIntervalSince(startedAt)
    }

    /// Streaming percentage as a fraction of observed time. Unknown time is excluded, not counted as failure.
    /// Returns nil when observed time is too short to be meaningful.
    var streamingFraction: Double? {
        guard observedSeconds > 5 else { return nil }
        return min(1, streamingSeconds / observedSeconds)
    }

    var isComplete: Bool { lifecycle == .closed }

    /// Closed sessions with no OBD data and the device never reporting "driving" are bench tests.
    /// Active/open sessions are `.unknown` until they close; legacy sessions without the flags default to `.unknown`.
    var quality: Quality {
        guard lifecycle == .closed else { return .unknown }
        if obdReceived || deviceReportedDriving { return .drive }
        return .bench
    }

    enum Quality: String, Codable, Sendable {
        case unknown, bench, drive
    }
}
