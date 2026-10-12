import CairnCore
import Foundation

enum SnapshotArchive {
    enum ArchiveError: Error, LocalizedError {
        case manifestMissing
        case unsupportedSchema(Int)
        case serverNewerThanApp(Int)

        var errorDescription: String? {
            switch self {
            case .manifestMissing: "Snapshot archive missing manifest.json"
            case .unsupportedSchema(let v): "Unsupported snapshot schema version \(v)"
            case .serverNewerThanApp(let v): "The server sent a newer snapshot format (schema \(v)). Update Cairn from TestFlight."
            }
        }
    }

    struct ExtractedSnapshot {
        let manifest: SnapshotManifest
        let parquetDir: URL
    }

    static func extract(archive: Data, to baseDir: URL) throws -> ExtractedSnapshot {
        let entries = TarReader.entries(from: archive)

        let parquetDir = baseDir.appendingPathComponent("parquet", isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: parquetDir.path) {
            try fm.removeItem(at: parquetDir)
        }
        try fm.createDirectory(at: parquetDir, withIntermediateDirectories: true)

        var manifest: SnapshotManifest?
        for entry in entries {
            let filename = (entry.name as NSString).lastPathComponent
            if filename == "manifest.json" {
                manifest = try SnapshotManifest.decode(from: entry.data)
            } else if filename.hasSuffix(".parquet") {
                let dest = parquetDir.appendingPathComponent(filename)
                try entry.data.write(to: dest, options: .atomic)
            }
        }

        guard let manifest else { throw ArchiveError.manifestMissing }
        guard manifest.isSupported else {
            throw manifest.isNewerThanSupported
                ? ArchiveError.serverNewerThanApp(manifest.schemaVersion)
                : ArchiveError.unsupportedSchema(manifest.schemaVersion)
        }

        return ExtractedSnapshot(manifest: manifest, parquetDir: parquetDir)
    }
}
