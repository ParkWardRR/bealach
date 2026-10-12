import Foundation

public struct SnapshotManifest: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var builtAt: Date
    public var decoderVersion: Int
    public var bundleCount: Int
    public var rowCounts: [String: Int]
    public var tables: [String]
    /// Vehicles whose rows the archive holds (schema 2 onward; nil for schema 1).
    public var vehicles: [String]?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case builtAt = "built_at"
        case decoderVersion = "decoder_version"
        case bundleCount = "bundle_count"
        case rowCounts = "row_counts"
        case tables
        case vehicles
    }

    /// Schema 2 adds a vehicle_id column to every table and the manifest's `vehicles`. The app
    /// reads per-trip rows keyed by boot_id and takes vehicle_id when present, so it reads 1 and 2.
    /// A schema it does not know is refused rather than guessed at.
    public static let supportedSchemaVersions = 1...2

    public var isSupported: Bool { Self.supportedSchemaVersions.contains(schemaVersion) }

    /// True when the server is newer than this app, so the fix is to update the app.
    public var isNewerThanSupported: Bool { schemaVersion > Self.supportedSchemaVersions.upperBound }

    public var totalRows: Int { rowCounts.values.reduce(0, +) }

    public var tripCount: Int { rowCounts["drive_summary"] ?? 0 }

    public static func decode(from data: Data) throws -> SnapshotManifest {
        let decoder = JSONDecoder()
        // The server writes RFC 3339 and drops the fractional part only when it happens to be
        // zero, so both "…:37Z" and "…:37.065997941Z" arrive. `.iso8601` accepts only the first.
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let plain = ISO8601DateFormatter()
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) ?? plain.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "not an RFC 3339 date: \(text)"
            ))
        }
        return try decoder.decode(SnapshotManifest.self, from: data)
    }
}
