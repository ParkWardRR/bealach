import Foundation

/// What the Trips list shows for one trip: the numbers a person scans for, derived from whichever
/// of the phone's session and the server's trip is present. Pure, so it is tested without a device.
public struct TripSummary: Identifiable, Sendable, Equatable {
    public let id: String
    public let startedAt: Date
    public let durationSeconds: TimeInterval
    /// Metres driven: along the dongle's GNSS track when the server has the trip, else the phone's own track.
    public let distanceMeters: Double?
    public let maxSpeedKph: Int?
    public let averageSpeedKph: Int?
    public let isBench: Bool
    public let isLive: Bool
    /// Normalised 0...1 points (x east, y north) for a map-free sketch of the route, thinned.
    public let routeSketch: [SketchPoint]
    /// The route as runs of places (a run ends at a dropout), for drawing on a map. The dongle's when the
    /// server has it, else the phone's.
    public let routeRuns: [[RoutePoint]]
    /// Fuel economy estimated from the dongle's MAF samples; nil without enough of them.
    public let fuel: FuelEstimate?
    /// Gallons burned over the distance, at that economy.
    public let fuelGallons: Double?

    public struct SketchPoint: Sendable, Equatable {
        public let x: Double
        public let y: Double
    }

    /// Fixes worse than this are not part of the route.
    public static let maxAccuracy = TrackPoint.maxAccuracy
    /// Implied speeds above this (about 200 km/h) mark a jump, not driving.
    static let maxImpliedMps = 56.0
    static let sketchPointLimit = 80

    public init(entry: HistoryEntry, ethanolPercent: Int = FuelEstimate.defaultEthanolPercent) {
        let session = entry.phoneSession
        let trip = entry.serverTrip
        self.id = entry.id
        self.startedAt = entry.startedAt
        self.isBench = session?.quality == .bench && trip == nil
        self.isLive = session.map { $0.lifecycle == .active || $0.lifecycle == .gapPending } ?? false

        // The dongle's own account of the trip is authoritative when the server has it.
        if let trip, trip.durationSeconds > 0 {
            self.durationSeconds = trip.durationSeconds
        } else {
            self.durationSeconds = session?.duration ?? 0
        }

        let usable = Self.usableTrack(session)
        let phoneRuns = usable.map { $0.map { RoutePoint(latitude: $0.latitude, longitude: $0.longitude) } }
        let serverRoute = trip?.route ?? []
        let runs = serverRoute.count >= 2 ? [serverRoute] : phoneRuns.filter { $0.count >= 2 }
        self.routeRuns = runs
        self.routeSketch = Self.sketch(of: runs.flatMap { $0 })

        // the dongle's GNSS distance when the server has one worth trusting, else what the phone drove
        let serverDistance = trip?.distanceMeters.flatMap { $0 > 50 ? $0 : nil }
        let distance = serverDistance ?? Self.distance(of: usable)
        self.distanceMeters = distance

        let trackMax = usable.flatMap { $0 }.compactMap { $0.speed >= 0 ? $0.speed * 3.6 : nil }.max()
        if let kph = trip?.maxSpeedKph {
            self.maxSpeedKph = kph
        } else {
            self.maxSpeedKph = trackMax.map { Int($0.rounded()) }
        }

        if let distance, durationSeconds >= 30, distance > 0 {
            self.averageSpeedKph = Int((distance / durationSeconds * 3.6).rounded())
        } else {
            self.averageSpeedKph = nil
        }

        let estimate = trip.flatMap { FuelEstimate(samples: $0.fuelSamples, ethanolPercent: ethanolPercent) }
        self.fuel = estimate
        self.fuelGallons = distance.flatMap { estimate?.gallons(overMeters: $0) }
    }

    // MARK: - Track maths

    /// The track as runs of good fixes; a run ends at a recorded gap, so nothing is drawn or
    /// measured across a dropout.
    public static func usableTrack(_ session: DriveSession?) -> [[TrackPoint]] {
        guard let session, !session.track.isEmpty else { return [] }
        let starts = Set(session.trackSegments.map(\.startIndex))
        var runs: [[TrackPoint]] = []
        var current: [TrackPoint] = []
        for (index, point) in session.track.enumerated() {
            if starts.contains(index), !current.isEmpty {
                runs.append(current)
                current = []
            }
            guard point.horizontalAccuracy >= 0, point.horizontalAccuracy <= maxAccuracy else { continue }
            if let last = current.last {
                let dt = point.timestamp.timeIntervalSince(last.timestamp)
                guard dt > 0 else { continue }
                if haversine(last, point) / dt > maxImpliedMps { continue }
            }
            current.append(point)
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    static func distance(of runs: [[TrackPoint]]) -> Double? {
        let total = runs.reduce(0.0) { sum, run in
            sum + zip(run, run.dropFirst()).reduce(0.0) { $0 + haversine($1.0, $1.1) }
        }
        return total > 0 ? total : nil
    }

    static func haversine(_ a: TrackPoint, _ b: TrackPoint) -> Double {
        let r = 6_371_000.0
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dp = p2 - p1
        let dl = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    static func sketch(of points: [RoutePoint]) -> [SketchPoint] {
        guard points.count >= 2 else { return [] }
        let stride = max(1, points.count / sketchPointLimit)
        let thinned = points.enumerated().filter { $0.offset % stride == 0 || $0.offset == points.count - 1 }.map(\.element)
        let lats = thinned.map(\.latitude), lons = thinned.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(), let minLon = lons.min(), let maxLon = lons.max() else { return [] }
        // Longitude degrees shrink with latitude; keep the shape true instead of stretched.
        let midLat = (minLat + maxLat) / 2
        let width = (maxLon - minLon) * cos(midLat * .pi / 180)
        let height = maxLat - minLat
        let scale = max(width, height)
        guard scale > 0 else { return [] }
        let xOffset = (scale - width) / 2, yOffset = (scale - height) / 2
        return thinned.map {
            SketchPoint(
                x: ((($0.longitude - minLon) * cos(midLat * .pi / 180)) + xOffset) / scale,
                y: (($0.latitude - minLat) + yOffset) / scale
            )
        }
    }
}

/// Trips grouped under a day heading, newest first.
public struct TripDay: Identifiable, Sendable, Equatable {
    public let id: Date
    public let trips: [TripSummary]
    public var totalDistanceMeters: Double { trips.compactMap(\.distanceMeters).reduce(0, +) }
    public var totalDuration: TimeInterval { trips.map(\.durationSeconds).reduce(0, +) }

    public static func group(_ trips: [TripSummary], calendar: Calendar = .current) -> [TripDay] {
        Dictionary(grouping: trips) { calendar.startOfDay(for: $0.startedAt) }
            .map { TripDay(id: $0.key, trips: $0.value.sorted { $0.startedAt > $1.startedAt }) }
            .sorted { $0.id > $1.id }
    }
}
