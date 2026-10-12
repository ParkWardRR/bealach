import CoreLocation
import Foundation

/// Raw Core Location values for one fix, decoupled from `CLLocation` so the encoder is testable.
/// Units follow Core Location: degrees, metres, m/s, degrees clockwise from true north.
/// Negative accuracy / speed / course mean "invalid" and are mapped per docs/ios-app.md.
public struct PhoneGNSSFix: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    /// Height above the WGS-84 ellipsoid (not MSL).
    public var ellipsoidalAltitude: Double
    public var horizontalAccuracy: Double
    public var verticalAccuracy: Double
    public var speed: Double
    public var course: Double
    public var timestamp: Date

    public init(
        latitude: Double,
        longitude: Double,
        ellipsoidalAltitude: Double,
        horizontalAccuracy: Double,
        verticalAccuracy: Double,
        speed: Double,
        course: Double,
        timestamp: Date
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.ellipsoidalAltitude = ellipsoidalAltitude
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.speed = speed
        self.course = course
        self.timestamp = timestamp
    }

    public init(_ location: CLLocation) {
        self.init(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            ellipsoidalAltitude: location.ellipsoidalAltitude,
            horizontalAccuracy: location.horizontalAccuracy,
            verticalAccuracy: location.verticalAccuracy,
            speed: location.speed,
            course: location.course,
            timestamp: location.timestamp
        )
    }
}
