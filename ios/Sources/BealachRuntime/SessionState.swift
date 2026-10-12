// Stubs for types that were in the Cairn app layer but not harvested.
// These provide the minimum surface area for BealachRuntime to compile.
// Replace with real implementations as Bealach features are built out.

import BealachCore
import Foundation
import Observation

/// Observable state of the BLE session: connection phase, device readings, event log.
/// The BLE manager writes this; the UI reads it.
@MainActor
@Observable
public final class SessionState {
    public enum Connection: Equatable, Sendable {
        case idle
        case scanning
        case connecting
        case bonding
        case ready
        case failed(String)
        case bluetoothUnavailable(String)
    }

    public var connection: Connection = .idle
    public var nextRetryAt: Date?
    public var retryAttempt: Int = 0
    public var connectedSince: Date?
    public var isStreaming: Bool = false

    // MARK: Device readings

    public var companionStatus: CompanionStatus?
    public var lastStatusAt: Date?
    public var deviceQuality: GNSSQuality?
    public var lastQualityAt: Date?
    public var obdLive: OBDLiveSnapshot?
    public var lastOBDAt: Date?
    public var deviceStatus: DeviceStatus?
    public var lastDeviceStatusAt: Date?

    // MARK: Event log

    public var eventLog = LinkEventLog()
    /// Alias used by some views.
    public var linkLog: LinkEventLog { eventLog }

    // MARK: Derived properties (used by views)

    /// Short label for the current connection phase.
    public var stage: String {
        switch connection {
        case .idle: "Idle"
        case .scanning: "Scanning"
        case .connecting: "Connecting"
        case .bonding: "Bonding"
        case .ready: isStreaming ? "Streaming" : "Ready"
        case .failed(let msg): "Failed: \(msg)"
        case .bluetoothUnavailable(let reason): reason
        }
    }

    public var isArmed: Bool { connection != .idle }

    /// Last known phone location status message (stub, phone GPS is not in Bealach scope).
    public var locationMessage: String? { nil }

    /// Last phone GNSS fix (stub).
    public var phoneFix: PhoneFixStub? { nil }

    public struct PhoneFixStub: Sendable {
        public var latitude: Double
        public var longitude: Double
        public var horizontalAccuracy: Double
        public var speed: Double
        public var timestamp: Date
    }

    /// Counters for the current connection.
    public var sentCount: Int = 0
    public var droppedCount: Int = 0

    /// A one-line detail about the current link state, e.g. retry timing.
    public func linkDetail(now: Date) -> String? {
        if let next = nextRetryAt {
            let seconds = Int(max(0, next.timeIntervalSince(now)))
            return "Retrying in \(seconds) s"
        }
        return nil
    }

    /// Summary of drops in this arming session.
    public func dropSummary(now: Date) -> String? {
        let drops = eventLog.dropCount
        guard drops > 0 else { return nil }
        return "\(drops) drop\(drops == 1 ? "" : "s")"
    }

    /// Whether a characteristic was heard recently enough to call "live".
    public func isLive(lastHeard: Date?, now: Date) -> Bool {
        guard let lastHeard else { return false }
        return now.timeIntervalSince(lastHeard) < LinkHealth.liveWindow
    }

    public init() {}

    public func record(_ kind: LinkEventKind, _ detail: String? = nil) {
        eventLog.append(LinkEvent(at: Date(), kind: kind, detail: detail))
    }

    public func resetDeviceState() {
        companionStatus = nil
        deviceQuality = nil
        obdLive = nil
        deviceStatus = nil
        connectedSince = nil
        isStreaming = false
    }

    public func clearDeviceReadings() {
        companionStatus = nil
        lastStatusAt = nil
        deviceQuality = nil
        lastQualityAt = nil
        obdLive = nil
        lastOBDAt = nil
        deviceStatus = nil
        lastDeviceStatusAt = nil
    }
}

/// Payload types for BLE characteristics that were in the app layer.
/// Defined here as minimal stubs so `BealachBLEManager` compiles.

public struct BaroAltPayload: Sendable {
    public var data: Data
    public init(data: Data) { self.data = data }
}

public struct UTCSyncPayload: Sendable {
    public var data: Data
    public init(data: Data) { self.data = data }
}

/// Stub for the driving session coordinator. The Cairn app managed location streaming,
/// arming, and session lifecycle here; Bealach will replace it with its own coordinator.
@MainActor
@Observable
public final class DrivingSession {
    public let ble: BealachBLEManager
    public let state: SessionState
    public let recorder: DriveRecorder

    public init(ble: BealachBLEManager, state: SessionState, recorder: DriveRecorder) {
        self.ble = ble
        self.state = state
        self.recorder = recorder
    }

    public func arm() {
        ble.start()
    }

    public func disarm() {
        ble.stop()
        recorder.disarmed()
    }

    public func forgetDongle() {
        ble.forgetDongle()
    }
}

// MARK: - Server setup stubs (not used in Bealach)

/// Parsed from a `cairn://configure` QR code. Bealach does not use server setup,
/// but the view references this type. Stubbed to let the module compile.
public struct ConfigureLink: Sendable {
    public var serverURL: String
    public var serverHost: String
    public var tailnetURL: String
    public var invitationCode: String
    public var caCertificateDER: Data?

    public init(serverURL: String = "", serverHost: String = "", tailnetURL: String = "",
                invitationCode: String = "", caCertificateDER: Data? = nil) {
        self.serverURL = serverURL
        self.serverHost = serverHost
        self.tailnetURL = tailnetURL
        self.invitationCode = invitationCode
        self.caCertificateDER = caCertificateDER
    }

    public static func parse(_ url: URL) throws -> ConfigureLink {
        ConfigureLink()
    }
}

/// Manages trust of the server's private CA. Stubbed for Bealach.
public enum PinnedCA {
    public struct SaveError: Error {}
    public static func save(der: Data) throws {}
}

/// Device enrolment error messages.
public enum DeviceEnrolment {
    public static func message(for error: Error) -> String {
        error.localizedDescription
    }
}

/// Notification posted when device setup changes (e.g. enrolment).
public extension Notification.Name {
    static let bealachSetupChanged = Notification.Name("bealachSetupChanged")
}

// MARK: - Server admin stubs (not used in Bealach)

/// An enrolled client shown in the admin panel. Stubbed for Bealach.
public struct ClientEntry: Identifiable, Sendable {
    public var id: String
    public var clientID: String
    public var name: String
    public var role: String
    public var publicKeyHex: String
    public var isRevoked: Bool

    public init(id: String = "", clientID: String = "", name: String = "", role: String = "", publicKeyHex: String = "", isRevoked: Bool = false) {
        self.id = id; self.clientID = clientID; self.name = name; self.role = role; self.publicKeyHex = publicKeyHex; self.isRevoked = isRevoked
    }
}

/// A registered device shown in the admin panel. Stubbed for Bealach.
public struct DeviceEntry: Identifiable, Sendable {
    public var id: String
    public var name: String

    public init(id: String = "", name: String = "") {
        self.id = id; self.name = name
    }
}

/// Dashboard access state. Stubbed for Bealach (no server dashboard).
@MainActor
@Observable
public final class DashboardAccess {
    public enum Status: Equatable {
        case unset
        case checking
        case signedOut(_ passkeyCount: Int)
        case signedIn(_ viaTailnet: Bool, _ user: String, _ host: String)
        case unreachable
    }
    public var isOpen: Bool = false
    public var sameHost: Bool = false
    public var serverURL: String = ""
    public var typedURL: String = ""
    public var status: Status = .unset
    public var url: URL?
    public var addressProblem: String?
    public var busy: Bool = false
    public var failed: Bool = false
    public var message: String?
    public init() {}
    public func refresh() async {}
    public func signIn() async {}
    public func signOut() async {}
}

/// HTTP client for the server API. Stubbed for Bealach (no server).
public struct BealachServerClient: Sendable {
    public init(transport: Any? = nil, signer: (any RequestSigner)? = nil) {}
    public func listClients() async throws -> [ClientEntry] { [] }
    public func revokeClient(_ clientID: String, reason: String) async throws {}
}

/// HTTP transport. Stubbed for Bealach (no server).
public struct URLSessionTransport: Sendable {
    public init(baseURL: URL, pinnedCA: Bool = false) {}
    public init(baseURL: String = "", pinnedCA: Bool = false) {}
}
