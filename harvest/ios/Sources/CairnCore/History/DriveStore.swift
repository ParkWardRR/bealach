import Foundation

/// Serialized access to persisted drive sessions. One implementation writes JSON files;
/// tests use an in-memory version. All mutations go through the store — views never write directly.
public protocol DriveStore: Sendable {
    func list() async throws -> [DriveSession]
    func list(vehicleID: String) async throws -> [DriveSession]
    func get(_ id: UUID) async throws -> DriveSession?
    func save(_ session: DriveSession) async throws
    func delete(_ id: UUID) async throws
    func deleteAll() async throws
}
