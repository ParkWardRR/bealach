import Foundation
import Testing
@testable import CairnCore

@Suite struct SnapshotManifestTests {
    // The manifest cairn-tsdb served on 2026-10-07: schema 2, a fractional-second built_at,
    // and the vehicles list the old reader refused.
    static let realV2 = """
    {
        "schema_version": 2,
        "built_at": "2026-10-07T16:17:37.065997941Z",
        "build_ms": 0,
        "decoder_version": 3,
        "bundle_count": 13,
        "vehicles": [
            "01a10dad2a2f797e976089f8854953f0"
        ],
        "row_counts": {
            "boost": 0,
            "bundles": 13,
            "drive_summary": 0,
            "gap": 0,
            "imu": 897,
            "obd": 0,
            "position": 96,
            "status": 5,
            "transition": 5
        },
        "tables": [
            "bundles",
            "position",
            "imu",
            "obd",
            "boost",
            "status",
            "transition",
            "gap",
            "drive_summary"
        ],
        "compressed_size_bytes": 0,
        "content_digest": ""
    }
    """

    static func manifest(version: Int, builtAt: String = "2026-10-07T16:17:37Z") -> Data {
        Data("""
        {"schema_version": \(version), "built_at": "\(builtAt)", "decoder_version": 3, "bundle_count": 1,
         "row_counts": {"drive_summary": 2}, "tables": ["drive_summary"]}
        """.utf8)
    }

    @Test func readsTheManifestTheServerServesNow() throws {
        let m = try SnapshotManifest.decode(from: Data(Self.realV2.utf8))
        #expect(m.schemaVersion == 2)
        #expect(m.isSupported)
        #expect(m.vehicles == ["01a10dad2a2f797e976089f8854953f0"])
        #expect(m.tables.contains("drive_summary"))
        #expect(m.bundleCount == 13)
    }

    @Test func readsBothDateShapesTheServerWrites() throws {
        let whole = try SnapshotManifest.decode(from: Self.manifest(version: 2, builtAt: "2026-10-07T16:17:37Z"))
        let fractional = try SnapshotManifest.decode(from: Self.manifest(version: 2, builtAt: "2026-10-07T16:17:37.065997941Z"))
        #expect(whole.builtAt == Date(timeIntervalSince1970: 1_791_389_857))
        #expect(abs(fractional.builtAt.timeIntervalSince(whole.builtAt) - 0.066) < 0.001)
    }

    @Test func rejectsADateThatIsNotRFC3339() {
        #expect(throws: DecodingError.self) { try SnapshotManifest.decode(from: Self.manifest(version: 2, builtAt: "yesterday")) }
    }

    @Test func schemaOneStillLoadsAndHasNoVehiclesList() throws {
        let m = try SnapshotManifest.decode(from: Self.manifest(version: 1))
        #expect(m.isSupported)
        #expect(m.vehicles == nil)
    }

    @Test(arguments: [0, 3, 99])
    func refusesASchemaItDoesNotKnow(version: Int) throws {
        let m = try SnapshotManifest.decode(from: Self.manifest(version: version))
        #expect(!m.isSupported)
        #expect(m.isNewerThanSupported == (version > 2))
    }

    @Test func aStoredManifestRoundTripsThroughTheDefaultCoders() throws {
        // TripSyncClient caches the manifest with a plain JSONEncoder and reads it back with a
        // plain JSONDecoder, so the new field must survive that.
        let m = try SnapshotManifest.decode(from: Data(Self.realV2.utf8))
        let back = try JSONDecoder().decode(SnapshotManifest.self, from: try JSONEncoder().encode(m))
        #expect(back == m)
    }
}
