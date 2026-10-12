import CairnCore
import Foundation
import os

public actor FileVehicleStore: VehicleStore {
    private static let log = Logger(subsystem: "app.cairn.companion", category: "vehicles")
    nonisolated let root: URL
    private let selectedKey = "cairn.selectedVehicleID"
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("vehicles", isDirectory: true)
        self.root = dir
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private var vehiclesURL: URL { root.appendingPathComponent("vehicles.json") }
    private var assignmentsURL: URL { root.appendingPathComponent("assignments.json") }

    // MARK: - Vehicles

    public func listVehicles() throws -> [Vehicle] {
        guard FileManager.default.fileExists(atPath: vehiclesURL.path) else { return [] }
        let data = try Data(contentsOf: vehiclesURL)
        return try decoder.decode([Vehicle].self, from: data)
    }

    public func vehicle(_ id: String) throws -> Vehicle? {
        try listVehicles().first { $0.id == id }
    }

    public func saveVehicle(_ vehicle: Vehicle) throws {
        try ensureDirectory()
        var vehicles = (try? listVehicles()) ?? []
        if let idx = vehicles.firstIndex(where: { $0.id == vehicle.id }) {
            vehicles[idx] = vehicle
        } else {
            vehicles.append(vehicle)
        }
        let data = try encoder.encode(vehicles)
        try data.write(to: vehiclesURL, options: .atomic)
    }

    public func deleteVehicle(_ id: String) throws {
        var vehicles = (try? listVehicles()) ?? []
        vehicles.removeAll { $0.id == id }
        try ensureDirectory()
        let data = try encoder.encode(vehicles)
        try data.write(to: vehiclesURL, options: .atomic)
        if selectedVehicleID() == id {
            selectVehicle(nil)
        }
    }

    // MARK: - Assignments

    public func assignments() throws -> [VehicleAssignment] {
        guard FileManager.default.fileExists(atPath: assignmentsURL.path) else { return [] }
        let data = try Data(contentsOf: assignmentsURL)
        return try decoder.decode([VehicleAssignment].self, from: data)
    }

    public func assign(dongleID: String, to vehicleID: String) throws {
        try ensureDirectory()
        var list = (try? assignments()) ?? []
        list.removeAll { $0.dongleID == dongleID }
        list.append(VehicleAssignment(dongleID: dongleID, vehicleID: vehicleID))
        let data = try encoder.encode(list)
        try data.write(to: assignmentsURL, options: .atomic)
    }

    public func unassign(dongleID: String) throws {
        var list = (try? assignments()) ?? []
        list.removeAll { $0.dongleID == dongleID }
        try ensureDirectory()
        let data = try encoder.encode(list)
        try data.write(to: assignmentsURL, options: .atomic)
    }

    public nonisolated func vehicleID(forDongle dongleID: String) -> String? {
        let url = root.appendingPathComponent("assignments.json")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([VehicleAssignment].self, from: data) else { return nil }
        return list.first { $0.dongleID == dongleID }?.vehicleID
    }

    // MARK: - Selection

    public nonisolated func selectedVehicleID() -> String? {
        UserDefaults.standard.string(forKey: selectedKey)
    }

    public nonisolated func selectVehicle(_ id: String?) {
        if let id {
            UserDefaults.standard.set(id, forKey: selectedKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectedKey)
        }
    }
}
