import CairnCore
import Foundation
import Testing

@Suite("Vehicle")
struct VehicleTests {
    @Test func displayNameWithEngineCode() {
        let v = Vehicle(year: 2017, make: "BMW", model: "M240i", engineCode: "B58")
        #expect(v.displayName == "2017 BMW M240i — B58")
    }

    @Test func displayNameWithoutEngineCode() {
        let v = Vehicle(year: 2020, make: "Toyota", model: "Supra")
        #expect(v.displayName == "2020 Toyota Supra")
    }

    @Test func displayNameEmptyEngineCode() {
        let v = Vehicle(year: 2015, make: "BMW", model: "428i", engineCode: "")
        #expect(v.displayName == "2015 BMW 428i")
    }

    @Test func defaultsNotArchived() {
        let v = Vehicle(year: 2017, make: "BMW", model: "M240i")
        #expect(!v.isArchived)
    }

    @Test func stableID() {
        let v = Vehicle(id: "test-123", year: 2017, make: "BMW", model: "M240i")
        #expect(v.id == "test-123")
    }

    @Test func codableRoundTrip() throws {
        let v = Vehicle(year: 2017, make: "BMW", model: "M240i", engineCode: "B58")
        let data = try JSONEncoder().encode(v)
        let decoded = try JSONDecoder().decode(Vehicle.self, from: data)
        #expect(decoded == v)
    }

    @Test func hashable() {
        let v1 = Vehicle(id: "a", year: 2017, make: "BMW", model: "M240i")
        let v2 = Vehicle(id: "a", year: 2017, make: "BMW", model: "M240i")
        let set: Set<Vehicle> = [v1, v2]
        #expect(set.count == 1)
    }

    @Test func firmwareEngineProfileForKnownBMW() {
        // N20 → bmw-n20, B58 → bmw-b58. Make matching is case-insensitive.
        #expect(Vehicle(year: 2014, make: "BMW", model: "428i", engineCode: "N20").firmwareEngineProfileID == "bmw-n20")
        #expect(Vehicle(year: 2015, make: "bmw", model: "428i", engineCode: "n20").firmwareEngineProfileID == "bmw-n20")
        #expect(Vehicle(year: 2016, make: "BMW", model: "428i", engineCode: "N26").firmwareEngineProfileID == "bmw-n20")
        #expect(Vehicle(year: 2017, make: "BMW", model: "M240i", engineCode: "B58").firmwareEngineProfileID == "bmw-b58")
    }

    @Test func firmwareEngineProfileNilWhenUnknown() {
        // An unknown engine code or make returns nil so the dongle falls back to its own
        // discovery (VIN pattern, default) rather than being told something invalid.
        #expect(Vehicle(year: 2020, make: "BMW", model: "M3", engineCode: "S58").firmwareEngineProfileID == nil)
        #expect(Vehicle(year: 2015, make: "Audi", model: "S3", engineCode: "N20").firmwareEngineProfileID == nil)
        #expect(Vehicle(year: 2015, make: "BMW", model: "428i").firmwareEngineProfileID == nil)
        #expect(Vehicle(year: 2015, make: "BMW", model: "428i", engineCode: "").firmwareEngineProfileID == nil)
    }
}

@Suite("VehicleAssignment")
struct VehicleAssignmentTests {
    @Test func codableRoundTrip() throws {
        let a = VehicleAssignment(dongleID: "CAIRN-001", vehicleID: "v-123")
        let data = try JSONEncoder().encode(a)
        let decoded = try JSONDecoder().decode(VehicleAssignment.self, from: data)
        #expect(decoded == a)
    }
}

@Suite("DriveSession Vehicle")
struct DriveSessionVehicleTests {
    @Test func vehicleIDNilByDefault() {
        let s = DriveSession(deviceID: "test")
        #expect(s.vehicleID == nil)
    }

    @Test func vehicleIDSet() {
        let s = DriveSession(deviceID: "test", vehicleID: "v-123")
        #expect(s.vehicleID == "v-123")
    }

    @Test func schemaVersionBumped() {
        #expect(DriveSession.schemaVersion == 2)
    }

    @Test func codableWithVehicleID() throws {
        let s = DriveSession(deviceID: "d1", vehicleID: "v1")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(s)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DriveSession.self, from: data)
        #expect(decoded.vehicleID == "v1")
    }

    @Test func decodesV1WithoutVehicleID() throws {
        let s = DriveSession(deviceID: "d1")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(s)
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json.removeValue(forKey: "vehicleID")
        json["schemaVersion"] = 1
        data = try JSONSerialization.data(withJSONObject: json)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DriveSession.self, from: data)
        #expect(decoded.vehicleID == nil)
    }
}
