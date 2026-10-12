import Foundation

// MARK: - Output types

/// A contiguous run of driving within a trip, separated from other legs by a stationary dwell
/// longer than `TripSegmenter.legDwellThreshold`.
public struct Leg: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let startedAt: Date
    public let endedAt: Date
    public let distanceMeters: Double
    public let route: [RoutePoint]

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date,
        distanceMeters: Double,
        route: [RoutePoint]
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.distanceMeters = distanceMeters
        self.route = route
    }

    public var duration: TimeInterval {
        endedAt.timeIntervalSince(startedAt)
    }
}

/// A trip composed of one or more legs, separated from other trips by a recording gap longer than
/// `TripSegmenter.tripGapThreshold`. Per the recording contract (recording.md section 3.1), per-boot is not
/// per-trip: a power brownout does not force a new trip, and multiple trips can happen within one boot.
public struct Trip: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let legs: [Leg]

    public init(id: UUID = UUID(), legs: [Leg]) {
        self.id = id
        self.legs = legs
    }

    public var startedAt: Date {
        legs.first?.startedAt ?? .distantPast
    }

    public var endedAt: Date {
        legs.last?.endedAt ?? .distantPast
    }

    public var totalDistance: Double {
        legs.reduce(0) { $0 + $1.distanceMeters }
    }

    public var duration: TimeInterval {
        endedAt.timeIntervalSince(startedAt)
    }
}

// MARK: - Input type

/// A single time-ordered observation used by `TripSegmenter`. Callers map their raw data (track
/// points, GNSS samples, bundle frames) into this flat representation before segmenting.
public struct RecordingPoint: Sendable, Equatable {
    public let timestamp: Date
    /// Speed in metres per second. A negative value means speed is unknown.
    public let speedMps: Double
    public let latitude: Double
    public let longitude: Double

    public init(timestamp: Date, speedMps: Double, latitude: Double, longitude: Double) {
        self.timestamp = timestamp
        self.speedMps = speedMps
        self.latitude = latitude
        self.longitude = longitude
    }
}

// MARK: - Segmenter

/// Pure segmentation logic: recording data in, trips and legs out. No I/O, no state.
///
/// The thresholds come from `recording.md` section 3.1:
/// - A stationary dwell **longer than** 5 minutes ends a leg.
/// - A recording gap **longer than** 30 minutes ends a trip.
public enum TripSegmenter {

    /// A stationary dwell longer than this ends the current leg.
    public static let legDwellThreshold: TimeInterval = 5 * 60   // 5 minutes

    /// A recording gap longer than this ends the current trip.
    public static let tripGapThreshold: TimeInterval = 30 * 60   // 30 minutes

    /// Speed at or below this (m/s) is considered stationary for dwell detection.
    /// About 2 km/h -- covers GPS jitter while stopped.
    public static let stationarySpeedThreshold: Double = 0.56

    /// Segment an array of time-ordered `RecordingPoint`s into trips and legs.
    ///
    /// The input must be sorted by timestamp (oldest first). Empty input returns an empty array.
    /// The function is pure: same input always produces the same output.
    public static func segment(_ points: [RecordingPoint]) -> [Trip] {
        guard !points.isEmpty else { return [] }

        // 1. Split into recording runs separated by trip-level gaps (> 30 min).
        let runs = splitIntoRuns(points)

        // 2. Within each run, split into legs at stationary dwells (> 5 min).
        return runs.compactMap { run -> Trip? in
            let legs = splitIntoLegs(run)
            guard !legs.isEmpty else { return nil }
            return Trip(legs: legs)
        }
    }

    /// Convenience: segment from `DriveSession` track points. Multiple sessions are merged
    /// and sorted by timestamp before segmenting.
    public static func segment(sessions: [DriveSession]) -> [Trip] {
        let points = sessions
            .flatMap(\.track)
            .sorted { $0.timestamp < $1.timestamp }
            .map { RecordingPoint(
                timestamp: $0.timestamp,
                speedMps: $0.speed,
                latitude: $0.latitude,
                longitude: $0.longitude
            ) }
        return segment(points)
    }

    // MARK: - Internal

    /// Split points into runs where consecutive points are no more than `tripGapThreshold` apart.
    static func splitIntoRuns(_ points: [RecordingPoint]) -> [[RecordingPoint]] {
        var runs: [[RecordingPoint]] = []
        var current: [RecordingPoint] = [points[0]]

        for i in 1..<points.count {
            let gap = points[i].timestamp.timeIntervalSince(points[i - 1].timestamp)
            if gap > tripGapThreshold {
                runs.append(current)
                current = [points[i]]
            } else {
                current.append(points[i])
            }
        }
        runs.append(current)
        return runs
    }

    /// Within a single run (no trip-level gaps), split into legs at stationary dwells.
    ///
    /// A dwell is a contiguous span of points where every point has speed at or below
    /// `stationarySpeedThreshold` and the span is longer than `legDwellThreshold`.
    /// The dwell itself belongs to neither the preceding nor the following leg.
    static func splitIntoLegs(_ run: [RecordingPoint]) -> [Leg] {
        guard !run.isEmpty else { return [] }

        // Identify stationary spans.
        var legs: [Leg] = []
        var legStart = 0
        var dwellStart: Int?

        for i in 0..<run.count {
            let isStationary = run[i].speedMps >= 0 && run[i].speedMps <= stationarySpeedThreshold

            if isStationary {
                if dwellStart == nil {
                    dwellStart = i
                }
            } else {
                if let ds = dwellStart {
                    // Measure dwell from first stationary point to last stationary point (i-1),
                    // not to the next moving point (i). This ensures exactly-at-threshold dwells
                    // are not treated as splits.
                    let dwellDuration = run[i - 1].timestamp.timeIntervalSince(run[ds].timestamp)
                    if dwellDuration > legDwellThreshold {
                        // The leg runs from legStart up to (but not including) the dwell start.
                        let legPoints = Array(run[legStart..<ds])
                        if !legPoints.isEmpty {
                            legs.append(makeLeg(from: legPoints))
                        }
                        legStart = i
                    }
                    dwellStart = nil
                }
            }
        }

        // Check if the run ends in a dwell that is long enough to split.
        if let ds = dwellStart {
            let dwellDuration = run[run.count - 1].timestamp.timeIntervalSince(run[ds].timestamp)
            if dwellDuration > legDwellThreshold {
                // Close the leg before the trailing dwell.
                let legPoints = Array(run[legStart..<ds])
                if !legPoints.isEmpty {
                    legs.append(makeLeg(from: legPoints))
                }
                // No new leg starts because the run ends.
                return legs
            }
        }

        // Remaining points form the last leg.
        let remaining = Array(run[legStart...])
        if !remaining.isEmpty {
            legs.append(makeLeg(from: remaining))
        }

        return legs
    }

    /// Build a `Leg` from a slice of recording points.
    private static func makeLeg(from points: [RecordingPoint]) -> Leg {
        let route = points.map { RoutePoint(latitude: $0.latitude, longitude: $0.longitude) }
        let distance = zip(points, points.dropFirst()).reduce(0.0) { sum, pair in
            sum + haversine(pair.0, pair.1)
        }
        return Leg(
            startedAt: points.first!.timestamp,
            endedAt: points.last!.timestamp,
            distanceMeters: distance,
            route: route
        )
    }

    /// Haversine distance in metres between two recording points.
    static func haversine(_ a: RecordingPoint, _ b: RecordingPoint) -> Double {
        let r = 6_371_000.0
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dp = p2 - p1
        let dl = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }
}
