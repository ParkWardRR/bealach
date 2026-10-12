import Foundation
import Testing
@testable import BealachCore

// MARK: - Helpers

private let origin = Date(timeIntervalSince1970: 1_700_000_000)

/// Build a point at `secondsFromOrigin` with a given speed (m/s) and position.
private func point(
    at seconds: TimeInterval,
    speedMps: Double = 10,
    lat: Double = 37.0,
    lon: Double = -122.0
) -> RecordingPoint {
    RecordingPoint(
        timestamp: origin.addingTimeInterval(seconds),
        speedMps: speedMps,
        latitude: lat,
        longitude: lon
    )
}

/// Generate a run of points every `interval` seconds over `duration` seconds, all moving.
private func movingRun(
    startSeconds: TimeInterval = 0,
    duration: TimeInterval,
    interval: TimeInterval = 10,
    startLat: Double = 37.0,
    startLon: Double = -122.0
) -> [RecordingPoint] {
    var points: [RecordingPoint] = []
    var t: TimeInterval = 0
    var lat = startLat
    while t <= duration {
        points.append(point(
            at: startSeconds + t,
            speedMps: 15,
            lat: lat,
            lon: startLon
        ))
        t += interval
        lat += 0.0001 // slight drift so distance is non-zero
    }
    return points
}

/// Generate a stationary dwell: points every `interval` seconds for `duration` seconds at speed 0.
private func stationaryDwell(
    startSeconds: TimeInterval,
    duration: TimeInterval,
    interval: TimeInterval = 10,
    lat: Double = 37.5,
    lon: Double = -122.5
) -> [RecordingPoint] {
    var points: [RecordingPoint] = []
    var t: TimeInterval = 0
    while t <= duration {
        points.append(point(
            at: startSeconds + t,
            speedMps: 0,
            lat: lat,
            lon: lon
        ))
        t += interval
    }
    return points
}

// MARK: - Tests

@Suite struct TripSegmenterTests {

    @Test func emptyInputReturnsNoTrips() {
        let trips = TripSegmenter.segment([])
        #expect(trips.isEmpty)
    }

    // A continuous drive with no stops or gaps -> one trip, one leg.
    @Test func continuousDriveProducesOneTripOneLeg() {
        let points = movingRun(duration: 600) // 10 minutes of driving
        let trips = TripSegmenter.segment(points)
        #expect(trips.count == 1)
        #expect(trips[0].legs.count == 1)
        #expect(trips[0].totalDistance > 0)
        #expect(trips[0].startedAt == points.first!.timestamp)
        #expect(trips[0].endedAt == points.last!.timestamp)
    }

    // A drive with a 6-minute stationary stop in the middle -> one trip, two legs.
    @Test func sixMinuteStopSplitsIntoTwoLegs() {
        let driveA = movingRun(startSeconds: 0, duration: 300) // 5 min driving
        let stop = stationaryDwell(startSeconds: 310, duration: 360) // 6 min stop (> 5 min threshold)
        let driveB = movingRun(startSeconds: 680, duration: 300, startLat: 37.5, startLon: -122.5)

        let points = (driveA + stop + driveB).sorted { $0.timestamp < $1.timestamp }
        let trips = TripSegmenter.segment(points)

        #expect(trips.count == 1)
        #expect(trips[0].legs.count == 2)
        // Both legs should have non-zero distance
        #expect(trips[0].legs[0].distanceMeters > 0)
        #expect(trips[0].legs[1].distanceMeters > 0)
    }

    // A 35-minute gap between two recording runs -> two trips.
    @Test func thirtyFiveMinuteGapSplitsIntoTwoTrips() {
        let driveA = movingRun(startSeconds: 0, duration: 300) // 5 min
        // 35-minute gap (> 30 min threshold): no points between 300 and 2400
        let driveB = movingRun(startSeconds: 2400, duration: 300, startLat: 38.0) // starts 35 min later

        let points = driveA + driveB
        let trips = TripSegmenter.segment(points)

        #expect(trips.count == 2)
        #expect(trips[0].legs.count == 1)
        #expect(trips[1].legs.count == 1)
    }

    // Exactly 5 minutes of stationary dwell -> still one leg (threshold is strictly greater than).
    @Test func exactlyFiveMinuteStopDoesNotSplitLeg() {
        let driveA = movingRun(startSeconds: 0, duration: 300)
        let stop = stationaryDwell(startSeconds: 310, duration: 300) // exactly 5 min
        let driveB = movingRun(startSeconds: 620, duration: 300, startLat: 37.5, startLon: -122.5)

        let points = (driveA + stop + driveB).sorted { $0.timestamp < $1.timestamp }
        let trips = TripSegmenter.segment(points)

        #expect(trips.count == 1)
        #expect(trips[0].legs.count == 1) // not split because dwell == threshold, not >
    }

    // Exactly 30 minutes of gap -> still one trip (threshold is strictly greater than).
    @Test func exactlyThirtyMinuteGapDoesNotSplitTrip() {
        let driveA = movingRun(startSeconds: 0, duration: 300)
        // Exactly 30-minute gap: last point of driveA near t=300, first of driveB at t=2100
        // gap = 2100 - 300 = 1800 = 30 min exactly
        let driveB = movingRun(startSeconds: 2100, duration: 300, startLat: 38.0)

        // Ensure the gap is exactly 30 min from last point of A to first point of B.
        let lastA = driveA.last!.timestamp
        let firstB = driveB.first!.timestamp
        let gap = firstB.timeIntervalSince(lastA)
        // gap should be exactly 1800 seconds
        #expect(gap == 1800)

        let points = driveA + driveB
        let trips = TripSegmenter.segment(points)

        #expect(trips.count == 1) // not split because gap == threshold, not >
    }

    // Multiple legs in one trip, multiple trips in one sequence.
    @Test func complexScenarioMultipleTripsAndLegs() {
        // Trip 1: two legs with a 6-min stop between them
        let drive1a = movingRun(startSeconds: 0, duration: 200)
        let stop1 = stationaryDwell(startSeconds: 210, duration: 400) // ~6.7 min stop
        let drive1b = movingRun(startSeconds: 620, duration: 200, startLat: 37.5)

        // 35-min gap -> trip boundary
        // Trip 2: one leg
        let drive2 = movingRun(startSeconds: 3000, duration: 300, startLat: 38.0) // starts 35+ min after 820

        let points = (drive1a + stop1 + drive1b + drive2).sorted { $0.timestamp < $1.timestamp }
        let trips = TripSegmenter.segment(points)

        #expect(trips.count == 2)
        #expect(trips[0].legs.count == 2) // split by the 6-min dwell
        #expect(trips[1].legs.count == 1)
    }

    // Single point produces one trip with one leg.
    @Test func singlePointProducesOneTripOneLeg() {
        let points = [point(at: 0)]
        let trips = TripSegmenter.segment(points)

        #expect(trips.count == 1)
        #expect(trips[0].legs.count == 1)
        #expect(trips[0].totalDistance == 0)
    }

    // A trailing dwell at the end of data does not produce an empty leg.
    @Test func trailingDwellDoesNotCreateEmptyLeg() {
        let drive = movingRun(startSeconds: 0, duration: 300)
        let stop = stationaryDwell(startSeconds: 310, duration: 400) // > 5 min, at the end

        let points = (drive + stop).sorted { $0.timestamp < $1.timestamp }
        let trips = TripSegmenter.segment(points)

        #expect(trips.count == 1)
        #expect(trips[0].legs.count == 1)
        // The leg should end at the end of the driving portion, not the dwell
        #expect(trips[0].legs[0].endedAt == drive.last!.timestamp)
    }

    // Verify the leg's route contains the expected points.
    @Test func legRouteContainsCorrectPoints() {
        let points = movingRun(duration: 100, interval: 20)
        let trips = TripSegmenter.segment(points)
        let leg = trips[0].legs[0]

        #expect(leg.route.count == points.count)
        #expect(leg.route.first!.latitude == points.first!.latitude)
        #expect(leg.route.last!.latitude == points.last!.latitude)
    }

    // Thresholds are exposed and match the contract.
    @Test func thresholdsMatchContract() {
        #expect(TripSegmenter.legDwellThreshold == 300)   // 5 minutes
        #expect(TripSegmenter.tripGapThreshold == 1800)   // 30 minutes
    }
}
