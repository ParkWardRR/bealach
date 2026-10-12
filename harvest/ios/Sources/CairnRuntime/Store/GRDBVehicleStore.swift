import CairnCore
import Foundation
import GRDB
import os

public final class GRDBVehicleStore: VehicleStore, Sendable {
    private static let log = Logger(subsystem: "app.cairn.companion", category: "grdb-vehicles")
    private let db: CairnDatabase
    private let selectedKey = "cairn.selectedVehicleID"

    public init(db: CairnDatabase) {
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
                INSERT OR REPLACE INTO vehicle (id, year, make, model, engineCode, isArchived)
                VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [
                vehicle.id, vehicle.year, vehicle.make, vehicle.model,
                vehicle.engineCode, vehicle.isArchived,
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
            try Row.fetchAll(dbConn, sql: "SELECT * FROM vehicleAssignment")
                .map { VehicleAssignment(dongleID: $0["dongleID"], vehicleID: $0["vehicleID"]) }
        }
    }

    public func assign(dongleID: String, to vehicleID: String) async throws {
        try await db.dbPool.write { dbConn in
            try dbConn.execute(sql: """
                INSERT OR REPLACE INTO vehicleAssignment (dongleID, vehicleID) VALUES (?, ?)
            """, arguments: [dongleID, vehicleID])
        }
    }

    public func unassign(dongleID: String) async throws {
        try await db.dbPool.write { dbConn in
            try dbConn.execute(sql: "DELETE FROM vehicleAssignment WHERE dongleID = ?",
                               arguments: [dongleID])
        }
    }

    public nonisolated func vehicleID(forDongle dongleID: String) -> String? {
        try? db.dbPool.read { dbConn in
            try String.fetchOne(dbConn, sql: """
                SELECT vehicleID FROM vehicleAssignment WHERE dongleID = ?
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
            isArchived: row["isArchived"]
        )
    }
}
