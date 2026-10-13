import BealachCore
import Foundation
import Testing

// R3: no GNSS fix → GNSS_GAP; no plotted position; UTC uncertainty honest.

private let now = Date()

@Suite struct PayloadEncoderNoFixTests {
    @Test func invalidHorizontalAccuracyProducesNoPosition() throws {
        let payload = PayloadEncoder.encode(
            latitude: 37.0, longitude: -122.0,
            ellipsoidalAltitude: 100,
            horizontalAccuracy: -1, verticalAccuracy: 5,
            speed: 10, course: 90,
            timestamp: now, now: now, seq: 0
        )
        let p = try #require(payload)
        #expect(p.fixType == 0, "no fix when accuracy is invalid")
        #expect(!p.validity.contains(.position))
        #expect(p.latE7 == 0)
        #expect(p.lonE7 == 0)
        #expect(p.hAccCm == GNSSFixPayload.invalidU16)
    }

    @Test func nanCoordinatesProduceNoPosition() throws {
        let payload = PayloadEncoder.encode(
            latitude: .nan, longitude: -122.0,
            ellipsoidalAltitude: 100,
            horizontalAccuracy: 5, verticalAccuracy: 5,
            speed: 10, course: 90,
            timestamp: now, now: now, seq: 1
        )
        let p = try #require(payload)
        #expect(p.fixType == 0)
        #expect(!p.validity.contains(.position))
    }

    @Test func outOfRangeLatitudeProducesNoPosition() throws {
        let payload = PayloadEncoder.encode(
            latitude: 91, longitude: -122.0,
            ellipsoidalAltitude: 100,
            horizontalAccuracy: 5, verticalAccuracy: 5,
            speed: 10, course: 90,
            timestamp: now, now: now, seq: 2
        )
        let p = try #require(payload)
        #expect(!p.validity.contains(.position))
    }

    @Test func staleFixReturnsNil() {
        let stale = now.addingTimeInterval(-3)
        let payload = PayloadEncoder.encode(
            latitude: 37.0, longitude: -122.0,
            ellipsoidalAltitude: 100,
            horizontalAccuracy: 5, verticalAccuracy: 5,
            speed: 10, course: 90,
            timestamp: stale, now: now, seq: 3
        )
        #expect(payload == nil, "fixes older than 2s are dropped")
    }

    @Test func invalidSpeedUsesSentinel() throws {
        let payload = PayloadEncoder.encode(
            latitude: 37.0, longitude: -122.0,
            ellipsoidalAltitude: 100,
            horizontalAccuracy: 5, verticalAccuracy: 5,
            speed: -1, course: 90,
            timestamp: now, now: now, seq: 4
        )
        let p = try #require(payload)
        #expect(p.speedCmps == GNSSFixPayload.invalidU16)
        #expect(!p.validity.contains(.speed))
    }

    @Test func validFixHasCorrectType() throws {
        let payload = PayloadEncoder.encode(
            latitude: 37.0, longitude: -122.0,
            ellipsoidalAltitude: 100,
            horizontalAccuracy: 5, verticalAccuracy: 5,
            speed: 10, course: 90,
            timestamp: now, now: now, seq: 5
        )
        let p = try #require(payload)
        #expect(p.fixType == 2, "3D fix with valid altitude")
        #expect(p.validity.contains(.position))
        #expect(p.validity.contains(.altitude))
    }

    @Test func roundTripThroughData() throws {
        let original = PayloadEncoder.encode(
            latitude: 37.7749, longitude: -122.4194,
            ellipsoidalAltitude: 15.5,
            horizontalAccuracy: 3.2, verticalAccuracy: 4.1,
            speed: 12.5, course: 270.0,
            timestamp: now, now: now, seq: 42
        )
        let p = try #require(original)
        let decoded = try #require(GNSSFixPayload(data: p.data))
        #expect(decoded == p)
    }
}

@Suite struct TripSnapshotGNSSGapTests {
    @Test func noLocationWhenCoordinatesAbsent() {
        let trip = TripSnapshot(
            id: "t1", startedAt: now, durationSeconds: 600,
            gnssSamples: 50, fixSamples: 0, gapCount: 5, gapDurationMs: 100_000
        )
        #expect(!trip.hasLocation)
        #expect(trip.gnssGapSeconds == 100.0)
    }

    @Test func hasLocationWhenCoordinatesPresent() {
        let trip = TripSnapshot(
            id: "t2", startedAt: now, durationSeconds: 600,
            gnssSamples: 50, fixSamples: 50,
            startLat: 37.0, startLon: -122.0
        )
        #expect(trip.hasLocation)
    }

    @Test func zeroGapDurationReportsZeroSeconds() {
        let trip = TripSnapshot(
            id: "t3", startedAt: now, durationSeconds: 300,
            gapCount: 0, gapDurationMs: 0
        )
        #expect(trip.gnssGapSeconds == 0)
    }
}
