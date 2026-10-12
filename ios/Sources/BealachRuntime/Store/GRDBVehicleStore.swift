import BealachCore
import Foundation
import GRDB
import os

public final class GRDBVehicleStore: VehicleStore, Sendable {
    private static let log = Logger(subsystem: "app.bealach", category: "grdb-vehicles")
    private let db: BealachDatabase
    private let selectedKey = "bealach.selectedVehicleID"

    public init(db: BealachDatabase) {
        self.db = db
    }

    public func listVehicles() async throws -> [Vehicle] {
        try await db.dbPool.read { dbConn in
            try Row.fetchAll(dbConn, sql: "SELECT * FROM vehicle ORDER BY year DESC, make, model")
                .map { Self.vehicleFromRow($0) }
        }
    }

    public func vehicle(_ id: String) async throws -> Vehicle? {
        try await db.dbPool.read { dbConn in
            guard let row = try Row.fetchOne(dbConn, sql: "SELECT * FROM vehicle WHERE id = ?",
                                              arguments: [id]) else { return nil }
            return Self.vehicleFromRow(row)
        }
    }

    public func saveVehicle(_ vehicle: Vehicle) async throws {
        try await db.dbPool.write { dbConn in
            try dbConn.execute(sql: """
                INSERT OR REPLACE INTO vehicle
                (id, year, make, model, engineCode, vin, isArchived, category, identificationSource, identificationConfidence)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                vehicle.id, vehicle.year, vehicle.make, vehicle.model,
                vehicle.engineCode, vehicle.vin, vehicle.isArchived,
                vehicle.category.rawValue, vehicle.identificationSource.rawValue,
                vehicle.identificationConfidence.rawValue,
            ])
        }
    }

    public func deleteVehicle(_ id: String) async throws {
        try await db.dbPool.write { dbConn in
            try dbConn.execute(sql: "DELETE FROM vehicle WHERE id = ?", arguments: [id])
        }
        if selectedVehicleID() == id {
            selectVehicle(nil)
        }
    }

    public func assignments() async throws -> [VehicleAssignment] {
        try await db.dbPool.read { dbConn in
            try Row.fetchAll(dbConn, sql: "SELECT * FROM vehicleAssignment ORDER BY assignedAt DESC")
                .map { Self.assignmentFromRow($0) }
        }
    }

    public func activeAssignment(forDongle dongleID: String) async throws -> VehicleAssignment? {
        try await db.dbPool.read { dbConn in
            guard let row = try Row.fetchOne(dbConn, sql: """
                SELECT * FROM vehicleAssignment WHERE dongleID = ? AND endedAt IS NULL
                ORDER BY assignedAt DESC LIMIT 1
            """, arguments: [dongleID]) else { return nil }
            return Self.assignmentFromRow(row)
        }
    }

    public func assign(dongleID: String, to vehicleID: String) async throws {
        try await db.dbPool.write { dbConn in
            try dbConn.execute(sql: """
                UPDATE vehicleAssignment SET endedAt = ? WHERE dongleID = ? AND endedAt IS NULL
            """, arguments: [Date(), dongleID])
            try dbConn.execute(sql: """
                INSERT INTO vehicleAssignment (id, dongleID, vehicleID, assignedAt, source)
                VALUES (?, ?, ?, ?, ?)
            """, arguments: [UUID().uuidString, dongleID, vehicleID, Date(), "manual"])
        }
    }

    public func unassign(dongleID: String) async throws {
        try await db.dbPool.write { dbConn in
            try dbConn.execute(sql: """
                UPDATE vehicleAssignment SET endedAt = ? WHERE dongleID = ? AND endedAt IS NULL
            """, arguments: [Date(), dongleID])
        }
    }

    public nonisolated func vehicleID(forDongle dongleID: String) -> String? {
        try? db.dbPool.read { dbConn in
            try String.fetchOne(dbConn, sql: """
                SELECT vehicleID FROM vehicleAssignment WHERE dongleID = ? AND endedAt IS NULL
                ORDER BY assignedAt DESC LIMIT 1
            """, arguments: [dongleID])
        }
    }

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

    private static func vehicleFromRow(_ row: Row) -> Vehicle {
        Vehicle(
            id: row["id"],
            year: row["year"],
            make: row["make"],
            model: row["model"],
            engineCode: row["engineCode"],
            vin: row["vin"],
            isArchived: row["isArchived"],
            category: (row["category"] as String?).flatMap(Vehicle.Category.init(rawValue:)) ?? .personal,
            identificationSource: (row["identificationSource"] as String?).flatMap(Vehicle.IdentificationSource.init(rawValue:)) ?? .manual,
            identificationConfidence: (row["identificationConfidence"] as String?).flatMap(Vehicle.Confidence.init(rawValue:)) ?? .confirmed
        )
    }

    private static func assignmentFromRow(_ row: Row) -> VehicleAssignment {
        VehicleAssignment(
            id: row["id"],
            dongleID: row["dongleID"],
            vehicleID: row["vehicleID"],
            assignedAt: row["assignedAt"],
            endedAt: row["endedAt"],
            source: (row["source"] as String?).flatMap(VehicleAssignment.AssignmentSource.init(rawValue:)) ?? .manual
        )
    }
}
