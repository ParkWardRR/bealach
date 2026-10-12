import CairnCore
import Foundation
import os

/// JSON-per-drive persistence under Application Support. One file per session, plus a rebuildable index.
/// All mutations are serialized through an actor so concurrent saves and deletes cannot race.
public actor FileDriveStore: DriveStore {
    private static let log = Logger(subsystem: "app.cairn.companion", category: "store")
    private let root: URL
    private let indexURL: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
    private static let maxDrives = 200

    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("drives", isDirectory: true)
        self.root = dir
        self.indexURL = dir.appendingPathComponent("index.json")
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func fileURL(for id: UUID) -> URL {
        root.appendingPathComponent("\(id.uuidString).json")
    }

    // MARK: - DriveStore

    public func list() throws -> [DriveSession] {
        try ensureDirectory()
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "index.json" }
        return files.compactMap { url in
            do {
                let data = try Data(contentsOf: url)
                return try decoder.decode(DriveSession.self, from: data)
            } catch {
                Self.log.error("corrupt drive file \(url.lastPathComponent): \(error)")
                return nil
            }
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    public func list(vehicleID: String) throws -> [DriveSession] {
        try list().filter { $0.vehicleID == vehicleID }
    }

    public func get(_ id: UUID) throws -> DriveSession? {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decoder.decode(DriveSession.self, from: data)
    }

    public func save(_ session: DriveSession) throws {
        try ensureDirectory()
        let data = try encoder.encode(session)
        let url = fileURL(for: session.id)
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: [.atomic])
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }

    public func delete(_ id: UUID) throws {
        let url = fileURL(for: id)
        try? FileManager.default.removeItem(at: url)
    }

    public func deleteAll() throws {
        try ensureDirectory()
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    // MARK: - Retention

    public func applyRetention() throws {
        let sessions = try list()
        guard sessions.count > Self.maxDrives else { return }
        let excess = sessions.suffix(from: Self.maxDrives)
        for session in excess where session.lifecycle == .closed {
            try delete(session.id)
        }
    }

    public func wipeV1DataIfNeeded() throws {
        try ensureDirectory()
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "index.json" }
        for url in files {
            guard let data = try? Data(contentsOf: url),
                  let session = try? decoder.decode(DriveSession.self, from: data),
                  session.schemaVersion < DriveSession.schemaVersion else { continue }
            try? FileManager.default.removeItem(at: url)
            Self.log.info("wiped v\(session.schemaVersion) drive \(url.lastPathComponent)")
        }
    }
}
