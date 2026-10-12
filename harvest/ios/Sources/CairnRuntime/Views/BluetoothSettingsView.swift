import CairnCore
import SwiftUI

public struct BluetoothSettingsView: View {
    let session: DrivingSession
    private let state: SessionState

    public init(session: DrivingSession) {
        self.session = session
        self.state = session.state
    }

    public var body: some View {
        Form {
            dongleSection
            troubleshootingSection
            connectionLogSection
            bleInfoSection
            actionsSection
        }
        .navigationTitle("Bluetooth")
    }

    // MARK: - Dongle

    @ViewBuilder
    private var dongleSection: some View {
        Section {
            HStack(spacing: 14) {
                connectionIcon
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Cairn Dongle")
                        .font(.body.weight(.medium))
                    Text(state.stage)
                        .font(.subheadline)
                        .foregroundStyle(stageColor)
                }
                Spacer()
                connectionBadge
            }
            .padding(.vertical, 4)

            if let since = state.connectedSince {
                LabeledContent("Connected") {
                    Text(since, style: .relative)
                        .foregroundStyle(.secondary)
                }
            }

            if let ds = state.deviceStatus {
                if let v = ds.batteryV {
                    LabeledContent("Battery") {
                        Text(String(format: "%.1f V", v))
                            .foregroundStyle(ds.batteryMv < 11500 ? .red : .secondary)
                    }
                }
                LabeledContent("Trip") {
                    Text(ds.tripPhase.label)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Uptime") {
                    Text(formatUptime(ds.uptimeS))
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Dongle")
        }
    }

    @ViewBuilder
    private var connectionIcon: some View {
        ZStack {
            Circle()
                .fill(stageColor.opacity(0.14))
            Image(systemName: stageSymbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(stageColor)
        }
    }

    @ViewBuilder
    private var connectionBadge: some View {
        Text(badgeLabel)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(stageColor.opacity(0.14), in: Capsule())
            .foregroundStyle(stageColor)
    }

    private var badgeLabel: String {
        switch state.connection {
        case .idle: "Off"
        case .bluetoothUnavailable: "Unavailable"
        case .scanning: "Scanning"
        case .connecting, .bonding: "Connecting"
        case .ready: state.isStreaming ? "Streaming" : "Connected"
        case .failed: "Failed"
        }
    }

    private var stageColor: Color {
        switch state.connection {
        case .idle: .secondary
        case .bluetoothUnavailable, .failed: Tone.bad.color
        case .scanning, .connecting, .bonding: Tone.warn.color
        case .ready: state.isStreaming ? Tone.good.color : .accentColor
        }
    }

    private var stageSymbol: String {
        switch state.connection {
        case .idle: "power"
        case .bluetoothUnavailable: "bolt.horizontal.circle"
        case .scanning: "dot.radiowaves.left.and.right"
        case .connecting, .bonding: "link"
        case .ready: state.isStreaming ? "antenna.radiowaves.left.and.right" : "checkmark.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    // MARK: - Troubleshooting

    @ViewBuilder
    private var troubleshootingSection: some View {
        Section {
            checkRow("Bluetooth power", passed: bluetoothOn, failHint: "Turn on Bluetooth in Control Center or Settings.")
            checkRow("Bluetooth permission", passed: bluetoothPermitted, failHint: "Go to Settings > Privacy > Bluetooth and allow Cairn Companion.")
            checkRow("Dongle in range", passed: dongleReachable, failHint: "Make sure the dongle is powered on and within range.")
            checkRow("Bond valid", passed: bondValid, failHint: "The pairing keys are stale. Use Forget Dongle, then go to Settings > Bluetooth > Cairn > Forget This Device, and re-pair.")
            checkRow("Protocol compatible", passed: protocolOk, failHint: "The dongle firmware version is not compatible with this app. Update the firmware or the app.")
        } header: {
            Text("Troubleshooting")
        } footer: {
            Text("Each check evaluates the current state. A failing check tells you what to do next.")
        }
    }

    private var bluetoothOn: Bool? {
        switch state.connection {
        case .bluetoothUnavailable(let msg) where msg == "Bluetooth is off": false
        case .idle where !state.isArmed: nil
        default: true
        }
    }

    private var bluetoothPermitted: Bool? {
        switch state.connection {
        case .bluetoothUnavailable(let msg) where msg == "Bluetooth permission denied": false
        case .idle where !state.isArmed: nil
        default: true
        }
    }

    private var dongleReachable: Bool? {
        switch state.connection {
        case .idle where !state.isArmed: nil
        case .scanning: false
        case .connecting, .bonding, .ready: true
        case .failed: false
        default: bluetoothOn == false ? nil : nil
        }
    }

    private var bondValid: Bool? {
        if case .failed(let msg) = state.connection, msg.hasPrefix("Stale pairing") { return false }
        if case .ready = state.connection { return true }
        return nil
    }

    private var protocolOk: Bool? {
        if case .failed(let msg) = state.connection, msg.hasPrefix("Unsupported protocol") { return false }
        if case .ready = state.connection { return true }
        return nil
    }

    @ViewBuilder
    private func checkRow(_ label: String, passed: Bool?, failHint: String) -> some View {
        HStack(spacing: 12) {
            Group {
                switch passed {
                case .some(true):
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .some(false):
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                case .none:
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.body)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.subheadline)
                if passed == false {
                    Text(failHint)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Connection Log

    @ViewBuilder
    private var connectionLogSection: some View {
        let events = state.linkLog.events
        if !events.isEmpty {
            Section {
                ForEach(events.suffix(20).reversed(), id: \.at) { event in
                    HStack(spacing: 10) {
                        Image(systemName: eventSymbol(event.kind))
                            .font(.caption)
                            .foregroundStyle(eventColor(event.kind))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(eventLabel(event.kind))
                                .font(.subheadline)
                            if let detail = event.detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        Text(event.at, style: .time)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            } header: {
                Text("Connection Log")
            } footer: {
                Text("Last \(min(events.count, 20)) of \(events.count) events this session.")
            }
        }
    }

    private func eventSymbol(_ kind: LinkEventKind) -> String {
        switch kind {
        case .armed: "power"
        case .disarmed: "power.circle"
        case .bluetoothUnavailable: "bolt.horizontal.circle"
        case .ready: "checkmark.circle.fill"
        case .dropped: "wifi.exclamationmark"
        case .failed: "xmark.circle.fill"
        case .streamingResumed: "antenna.radiowaves.left.and.right"
        case .streamingLost: "antenna.radiowaves.left.and.right.slash"
        }
    }

    private func eventColor(_ kind: LinkEventKind) -> Color {
        switch kind {
        case .armed, .ready, .streamingResumed: .green
        case .disarmed: .secondary
        case .bluetoothUnavailable, .dropped, .streamingLost: .orange
        case .failed: .red
        }
    }

    private func eventLabel(_ kind: LinkEventKind) -> String {
        switch kind {
        case .armed: "Armed"
        case .disarmed: "Disarmed"
        case .bluetoothUnavailable: "Bluetooth unavailable"
        case .ready: "Link ready"
        case .dropped: "Link dropped"
        case .failed: "Failed"
        case .streamingResumed: "Streaming resumed"
        case .streamingLost: "Streaming lost"
        }
    }

    // MARK: - BLE Info

    @ViewBuilder
    private var bleInfoSection: some View {
        Section {
            LabeledContent("Service UUID") {
                Text(CairnGATTProfile.serviceUUID.uuidString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            LabeledContent("Protocol version") {
                Text("v\(CairnGATTProfile.supportedMajorVersion)")
                    .foregroundStyle(.secondary)
            }

            if state.connection == .ready {
                LabeledContent("GNSS Fix") {
                    Text("Write without response")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let q = state.deviceQuality {
                    LabeledContent("Satellites") {
                        Text(q.satsUsed == 0xFF ? "Unknown" : "\(q.satsUsed)")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let ds = state.deviceStatus {
                let h = ds.health
                LabeledContent("Device health") {
                    HStack(spacing: 6) {
                        healthDot("OBD", ok: h.contains(.obdOk))
                        healthDot("GNSS", ok: h.contains(.gnssOk))
                        healthDot("SD", ok: h.contains(.sdOk))
                        healthDot("IMU", ok: h.contains(.imuOk))
                    }
                }
            }
        } header: {
            Text("BLE Info")
        }
    }

    @ViewBuilder
    private func healthDot(_ label: String, ok: Bool) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(ok ? .green : .red)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            if !state.isArmed {
                Button {
                    session.arm()
                } label: {
                    Label("Start Auto-Connect", systemImage: "power")
                }
            } else {
                Button {
                    session.disarm()
                } label: {
                    Label("Stop Auto-Connect", systemImage: "power.circle")
                        .foregroundStyle(.orange)
                }
            }

            Button(role: .destructive) {
                session.forgetDongle()
            } label: {
                Label("Forget Dongle", systemImage: "minus.circle")
            }
        } header: {
            Text("Actions")
        } footer: {
            Text("Forgetting the dongle clears its identity from the app. You must also forget \"Cairn\" in iOS Settings > Bluetooth to fully remove the pairing.")
        }
    }

    // MARK: - Helpers

    private func formatUptime(_ seconds: UInt32) -> String {
        if seconds >= 3600 {
            return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
        } else if seconds >= 60 {
            return "\(seconds / 60)m \(seconds % 60)s"
        }
        return "\(seconds)s"
    }
}

private extension DeviceStatus.TripPhase {
    var label: String {
        switch self {
        case .idle: "Idle"
        case .driving: "Driving"
        case .paused: "Paused"
        case .unknown: "Unknown"
        }
    }
}
