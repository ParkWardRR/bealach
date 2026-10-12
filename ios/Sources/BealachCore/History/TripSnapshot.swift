// Provenance: cairn-ios-companion-app @ a7d02d8, Sources/CairnCore/History/TripSnapshot.swift
// Renamed Cairn* → Bealach* for Bealach. Server (cairn-tsdb) references removed.

import Foundation

/// A trip derived locally from bundle data on the phone. The phone segments continuous recordings
/// into trips per the contract (recording.md §3.1): gaps > 30 min end a trip, stationary dwells
/// > 5 min end a leg.
public struct TripSnapshot: Codable, Identifiable, Sendable, Equatable {
    /// Locally-generated identifier: bundle_id + time range hash.
    public let id: String
    public var startedAt: Date
    public var endedAt: Date?
    public var durationSeconds: TimeInterval

    public var maxSpeedKph: Int?
    public var maxRpm: Int?
    public var obdSamples: Int
    public var gnssSamples: Int
    public var fixSamples: Int
    public var gapCount: Int
    public var gapDurationMs: Int
    public var warnings: String?

    public var startLat: Double?
    public var startLon: Double?

    /// Metres along the GNSS track (fixes no more than 5 s apart), computed by the phone from bundle data.
    public var distanceMeters: Double?
    /// The track thinned for drawing. Empty when bundle data has no positions for this trip.
    public var route: [RoutePoint] = []
    /// MAF and lambda moments for a fuel estimate; empty when the bundle has none.
    public var fuelSamples: [FuelSample] = []

    /// 16-byte UUID of the dongle that recorded this trip, from the bundle manifest.
    public var deviceID: Data?

    public init(
        id: String, startedAt: Date, endedAt: Date? = nil,
        durationSeconds: TimeInterval,
        maxSpeedKph: Int? = nil, maxRpm: Int? = nil,
        obdSamples: Int = 0, gnssSamples: Int = 0,
        fixSamples: Int = 0,
        gapCount: Int = 0, gapDurationMs: Int = 0,
        warnings: String? = nil,
        startLat: Double? = nil, startLon: Double? = nil,
        deviceID: Data? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.maxSpeedKph = maxSpeedKph
        self.maxRpm = maxRpm
        self.obdSamples = obdSamples
        self.gnssSamples = gnssSamples
        self.fixSamples = fixSamples
        self.gapCount = gapCount
        self.gapDurationMs = gapDurationMs
        self.warnings = warnings
        self.startLat = startLat
        self.startLon = startLon
        self.deviceID = deviceID
    }

    public var gnssGapSeconds: TimeInterval {
        Double(gapDurationMs) / 1000.0
    }

    public var hasLocation: Bool {
        startLat != nil && startLon != nil
    }
}

/// One place along a track, for drawing a route.
public struct RoutePoint: Codable, Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// Combined view for the History tab: a phone-observed session optionally paired with a
/// locally-derived trip from bundle data.
public struct HistoryEntry: Identifiable, Sendable {
    public let id: String
    public var session: DriveSession?
    public var trip: TripSnapshot?

    public init(session: DriveSession? = nil, trip: TripSnapshot? = nil) {
        if let s = session { self.id = s.id.uuidString }
        else if let t = trip { self.id = t.id }
        else { self.id = UUID().uuidString }
        self.session = session
        self.trip = trip
    }

    public var startedAt: Date {
        session?.startedAt ?? trip?.startedAt ?? .distantPast
    }

    public var hasSession: Bool { session != nil }
    public var hasTrip: Bool { trip != nil }
    public var isSessionOnly: Bool { session != nil && trip == nil }
    public var isTripOnly: Bool { session == nil && trip != nil }
}
