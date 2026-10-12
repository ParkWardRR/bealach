import BealachCore
import SwiftUI

public struct DeviceDetailView: View {
    let state: SessionState
    @State private var deviceInfo: DeviceInfo?

    public init(state: SessionState) {
        self.state = state
    }

    public var body: some View {
        List {
            if let info = deviceInfo {
                identitySection(info)
                firmwareSection(info)
                bootTimingSection(info)
                storageSection(info)
                capabilitiesSection(info)
                if !info.engines.isEmpty {
                    enginesSection(info)
                }
                if !info.transports.isEmpty {
                    transportsSection(info)
                }
            } else {
                ContentUnavailableView(
                    "Not Connected",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: Text("Connect to the dongle to see device details.")
                )
            }
        }
        .navigationTitle("Device")
        .task { await pollDeviceInfo() }
    }

    private func pollDeviceInfo() async {
        // TODO: read DEVICE_INFO characteristic when BLE offload pipeline is wired
    }

    // MARK: - Identity

    @ViewBuilder
    private func identitySection(_ info: DeviceInfo) -> some View {
        if let id = info.identity {
            Section("Identity") {
                LabeledContent("Device ID", value: id.deviceID.map { String(format: "%02x", $0) }.joined())
                LabeledContent("Fingerprint", value: id.fingerprint.map { String(format: "%02x", $0) }.joined())
                LabeledContent("Enrolment") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(enrolColor(id.enrolState))
                            .frame(width: 8, height: 8)
                        Text(enrolLabel(id.enrolState))
                    }
                }
                LabeledContent("Storage Key", value: "v\(id.storageKeyVersion)")
            }
        }
    }

    private func enrolColor(_ state: DeviceInfo.Identity.EnrolState) -> Color {
        switch state {
        case .notEnrolled: .orange
        case .enrolled: .blue
        case .assigned: .green
        }
    }

    private func enrolLabel(_ state: DeviceInfo.Identity.EnrolState) -> String {
        switch state {
        case .notEnrolled: "Not enrolled"
        case .enrolled: "Enrolled"
        case .assigned: "Assigned"
        }
    }

    // MARK: - Firmware

    @ViewBuilder
    private func firmwareSection(_ info: DeviceInfo) -> some View {
        if let fw = info.firmware {
            Section("Firmware") {
                LabeledContent("Version", value: "\(fw.major).\(fw.minor).\(fw.patch)")
                LabeledContent("Commit", value: fw.commit.prefix(4).map { String(format: "%02x", $0) }.joined())
                LabeledContent("Built") {
                    Text(Date(timeIntervalSince1970: TimeInterval(fw.buildUnix)), style: .date)
                }
                if fw.isDirtyBuild {
                    Label("Dirty build", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                HStack(spacing: 12) {
                    flagBadge("Release", on: fw.isReleaseBuild)
                    flagBadge("Secure Boot", on: fw.secureBootOn)
                    flagBadge("Flash Encrypt", on: fw.flashEncryptionOn)
                }
                .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func flagBadge(_ label: String, on: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(on ? .green : .secondary)
            Text(label).foregroundStyle(on ? .primary : .secondary)
        }
    }

    // MARK: - Boot Timing

    @ViewBuilder
    private func bootTimingSection(_ info: DeviceInfo) -> some View {
        if let bt = info.bootTiming {
            Section("Boot Timing") {
                LabeledContent("Boot → BLE", value: "\(bt.bootToBLEms) ms")
                LabeledContent("Boot → Ready", value: "\(bt.bootToReadyMs) ms")
                if let fix = bt.bootToFirstFixMs {
                    LabeledContent("Boot → First Fix", value: "\(fix) ms")
                } else {
                    LabeledContent("Boot → First Fix", value: "No fix yet")
                }
                LabeledContent("Reset Reason", value: resetReasonLabel(bt.resetReason))
            }
        }
    }

    private func resetReasonLabel(_ code: UInt8) -> String {
        switch code {
        case 1: "Power-on"
        case 3: "Software"
        case 5: "Deep sleep"
        case 7: "Brownout"
        case 12: "Watchdog (CPU)"
        case 13: "Watchdog (RTC)"
        case 15: "Watchdog (task)"
        default: "0x\(String(code, radix: 16))"
        }
    }

    // MARK: - Storage

    @ViewBuilder
    private func storageSection(_ info: DeviceInfo) -> some View {
        if let st = info.storage {
            Section("SD Card") {
                LabeledContent("State") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(storageColor(st.state))
                            .frame(width: 8, height: 8)
                        Text(storageLabel(st.state))
                    }
                }
                LabeledContent("Pending Bundles", value: "\(st.pendingBundles)")
                if let free = st.freeMiB {
                    LabeledContent("Free Space", value: free >= 1024 ? "\(free / 1024) GB" : "\(free) MB")
                }
            }
        }
    }

    private func storageColor(_ state: DeviceInfo.Storage.State) -> Color {
        switch state {
        case .ok: .green
        case .readOnly: .orange
        case .noCard, .error: .red
        }
    }

    private func storageLabel(_ state: DeviceInfo.Storage.State) -> String {
        switch state {
        case .noCard: "No card"
        case .ok: "OK"
        case .readOnly: "Read-only"
        case .error: "Error"
        }
    }

    // MARK: - Capabilities

    @ViewBuilder
    private func capabilitiesSection(_ info: DeviceInfo) -> some View {
        let caps = DeviceInfo.Capability.allCases.filter { info.supports($0) }
        if !caps.isEmpty {
            Section("Capabilities") {
                FlowLayout(spacing: 6) {
                    ForEach(caps, id: \.rawValue) { cap in
                        Text(capLabel(cap))
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
        }
    }

    private func capLabel(_ cap: DeviceInfo.Capability) -> String {
        switch cap {
        case .phoneGNSSCompanion: "Phone GNSS"
        case .liveOBD: "Live OBD"
        case .bundleOffload: "Bundle Offload"
        case .deviceInformation: "Device Info"
        case .uplinkEvents: "Uplink Events"
        case .instructions: "Instructions"
        case .homeTrigger: "Home Trigger"
        case .wiFiUplink: "Wi-Fi"
        case .lteUplink: "LTE"
        case .digest: "Digest"
        case .configuration: "Configuration"
        }
    }

    // MARK: - Engines

    @ViewBuilder
    private func enginesSection(_ info: DeviceInfo) -> some View {
        Section("Engine Profiles") {
            ForEach(info.engines, id: \.engineID) { engine in
                VStack(alignment: .leading, spacing: 4) {
                    Text(engine.engineID).font(.body.weight(.medium))
                    HStack(spacing: 12) {
                        Text("v\(engine.profileVersion)").font(.caption).foregroundStyle(.secondary)
                        Text(engine.hash.prefix(4).map { String(format: "%02x", $0) }.joined())
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Transports

    @ViewBuilder
    private func transportsSection(_ info: DeviceInfo) -> some View {
        Section("Transports") {
            ForEach(info.transports, id: \.kind) { t in
                HStack {
                    Text(transportLabel(t.kind)).font(.body)
                    Spacer()
                    HStack(spacing: 8) {
                        if t.hardwarePresent { badge("HW", .green) }
                        if t.compiledIn { badge("Built", .blue) }
                        if t.enabled { badge("On", .green) }
                        if t.availableNow { badge("Up", .green) }
                    }
                }
            }
        }
    }

    private func transportLabel(_ kind: DeviceInfo.Transport.Kind) -> String {
        switch kind {
        case .ble: "BLE"
        case .wifi: "Wi-Fi"
        case .lte: "LTE"
        }
    }

    @ViewBuilder
    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
