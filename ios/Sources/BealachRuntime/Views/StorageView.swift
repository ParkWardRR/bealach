import BealachCore
import SwiftUI

public struct StorageView: View {
    let session: DrivingSession
    let offload: OffloadController?
    @State private var bundles: [BundleState] = []
    @State private var isLoading = true

    public init(session: DrivingSession, offload: OffloadController? = nil) {
        self.session = session
        self.offload = offload
    }

    public var body: some View {
        List {
            deviceStorageSection
            phoneStorageSection
            if !bundles.isEmpty {
                bundleListSection
            }
        }
        .navigationTitle("Storage & Mirror")
        .task { await load() }
        .refreshable { await load() }
        .overlay {
            if bundles.isEmpty && !isLoading {
                ContentUnavailableView(
                    "No bundles yet",
                    systemImage: "externaldrive",
                    description: Text("Bundles appear here after a recording is sealed on the dongle and mirrored to this phone.")
                )
            }
        }
    }

    // MARK: - Device Storage

    @ViewBuilder
    private var deviceStorageSection: some View {
        if let ds = session.state.deviceStatus {
            Section("Dongle") {
                if let free = ds.sdFree {
                    HStack {
                        Label("SD Free", systemImage: "sdcard")
                        Spacer()
                        Text(free >= 1024 ? "\(free / 1024) GB" : "\(free) MB")
                            .foregroundStyle(free < 100 ? .red : .secondary)
                    }
                }
                HStack {
                    Label("Trip Phase", systemImage: "car.side")
                    Spacer()
                    Text(tripLabel(ds.tripPhase)).foregroundStyle(.secondary)
                }
                if let bat = ds.batteryV {
                    HStack {
                        Label("Battery", systemImage: "battery.100percent")
                        Spacer()
                        Text(String(format: "%.1f V", bat))
                            .foregroundStyle(bat < 11.5 ? .orange : .secondary)
                    }
                }
            }
        } else {
            Section("Dongle") {
                Label("Not connected", systemImage: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Phone Storage

    @ViewBuilder
    private var phoneStorageSection: some View {
        Section("Phone") {
            HStack {
                Label("Sessions", systemImage: "clock.arrow.circlepath")
                Spacer()
                Text("\(bundles.filter { $0.status == .verified }.count) verified")
                    .foregroundStyle(.secondary)
            }
            if let offload {
                HStack {
                    Label("Offload", systemImage: "arrow.down.circle")
                    Spacer()
                    Text(offload.isRunning ? "Running" : "Idle")
                        .foregroundStyle(offload.isRunning ? .blue : .secondary)
                }
                Button {
                    offload.offloadNow()
                } label: {
                    Label("Reconcile Now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(offload.isRunning || !offload.canOffload)
            }
        }
    }

    // MARK: - Bundle List

    @ViewBuilder
    private var bundleListSection: some View {
        Section("Bundles") {
            ForEach(bundles) { bundle in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(bundle.id.prefix(12))
                            .font(.caption.monospaced())
                        Text(bundle.date, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusBadge(status: bundle.status)
                }
            }
        }
    }

    private func tripLabel(_ phase: DeviceStatus.TripPhase) -> String {
        switch phase {
        case .idle: "Idle"
        case .driving: "Driving"
        case .paused: "Paused"
        case .unknown: "Unknown"
        }
    }

    private func load() async {
        isLoading = true
        // TODO: populate from offload controller's bundle inventory
        isLoading = false
    }
}

struct BundleState: Identifiable, Sendable {
    let id: String
    let date: Date
    let status: MirrorStatus
    let sizeBytes: Int64

    enum MirrorStatus: String, Sendable {
        case pending
        case transferring
        case verified
        case missing
    }
}

private struct StatusBadge: View {
    let status: BundleState.MirrorStatus

    var body: some View {
        Text(status.rawValue.capitalized)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .pending: .orange
        case .transferring: .blue
        case .verified: .green
        case .missing: .red
        }
    }
}
