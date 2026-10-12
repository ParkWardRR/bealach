import Foundation

public protocol VehicleStore: Sendable {
    func listVehicles() async throws -> [Vehicle]
    func vehicle(_ id: String) async throws -> Vehicle?
    func saveVehicle(_ vehicle: Vehicle) async throws
    func deleteVehicle(_ id: String) async throws

    func assignments() async throws -> [VehicleAssignment]
    func assign(dongleID: String, to vehicleID: String) async throws
    func unassign(dongleID: String) async throws
    func vehicleID(forDongle dongleID: String) -> String?

    func selectedVehicleID() -> String?
    func selectVehicle(_ id: String?)
}
