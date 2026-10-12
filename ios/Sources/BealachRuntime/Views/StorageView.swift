import BealachCore
import SwiftUI
import os

public struct StorageView: View {
    private static let log = Logger(subsystem: "app.bealach", category: "storage-view")
    let session: DrivingSession
    let offload: OffloadController?
    let reconciliationStore: GRDBReconciliationStore?
    @State private var snapshot: ReconciliationSnapshot?
    @State private var deletionIntents: [DeletionIntent] = []
    @State private var tombstones: [Tombstone] = []
    @State private var isLoading = true
    @State private var showDeleteIOSConfirm = false
    @State private var showClearMirrorConfirm = false
    @State private var selectedEntry: ReconciliationEntry?

    public init(session: DrivingSession, offload: OffloadController? = nil, reconciliationStore: GRDBReconciliationStore? = nil) {
        self.session = session
        self.offload = offload
        self.reconciliationStore = reconciliationStore
    }

    public var body: some View {
        List {
            deviceStorageSection
            phoneStorageSection
            if let snapshot, !snapshot.entries.isEmpty {
                reconciliationSection(snapshot)
            }
            if !deletionIntents.filter({ !$0.isTerminal }).isEmpty {
                activeDeletionsSection
            }
            if !tombstones.isEmpty {
                tombstoneSection
            }
            deleteActionsSection
        }
        .navigationTitle("Storage & Mirror")
        .task { await load() }
        .refreshable { await load() }
        .overlay {
            if snapshot == nil && !isLoading {
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
            if let snapshot {
                HStack {
                    Label("Verified", systemImage: "checkmark.shield")
                    Spacer()
                    Text("\(snapshot.verifiedCount)")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Label("Pending", systemImage: "clock")
                    Spacer()
                    Text("\(snapshot.pendingCount)")
                        .foregroundStyle(snapshot.pendingCount > 0 ? .orange : .secondary)
                }
                if snapshot.transferringCount > 0 {
                    HStack {
                        Label("Transferring", systemImage: "arrow.down.circle")
                        Spacer()
                        Text("\(snapshot.transferringCount)")
                            .foregroundStyle(.blue)
                    }
                }
                if snapshot.missingCount > 0 || snapshot.corruptCount > 0 {
                    HStack {
                        Label("Attention", systemImage: "exclamationmark.triangle")
                        Spacer()
                        Text("\(snapshot.missingCount + snapshot.corruptCount)")
                            .foregroundStyle(.red)
                    }
                }
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

    // MARK: - Reconciliation

    @ViewBuilder
    private func reconciliationSection(_ snapshot: ReconciliationSnapshot) -> some View {
        Section {
            ForEach(snapshot.entries) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.bundleID.prefix(12))
                                .font(.caption.monospaced())
                            Text(entry.contentRoot)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let progress = entry.transferProgress {
                            ProgressView(value: progress)
                                .frame(width: 60)
                        }
                        MirrorStateBadge(state: entry.state)
                    }
                    if entry.state != .verified {
                        Text(entry.discrepancyExplanation)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .contextMenu {
                    if entry.state == .verified {
                        Button(role: .destructive) {
                            selectedEntry = entry
                            showDeleteIOSConfirm = true
                        } label: {
                            Label("Delete iOS Copy", systemImage: "trash")
                        }
                    }
                    if entry.state == .deletedIntentionally {
                        Button {
                            Task { await fetchAgain(bundleID: entry.bundleID) }
                        } label: {
                            Label("Fetch Again", systemImage: "arrow.down.circle")
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("Bundles")
                Spacer()
                if snapshot.isStale {
                    Label("Stale", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        } footer: {
            Text("Snapshot from \(snapshot.computedAt.formatted(.relative(presentation: .named))). \(snapshot.isStale ? "Dongle is unreachable — this may not reflect current state." : "")")
        }
        .confirmationDialog(
            "Delete iOS copy?",
            isPresented: $showDeleteIOSConfirm,
            presenting: selectedEntry
        ) { entry in
            Button("Delete iOS Copy", role: .destructive) {
                Task { await deleteIOSCopy(entry) }
            }
        } message: { entry in
            Text("The SD original survives. The iPhone copy of \(entry.bundleID.prefix(8)) becomes unrecoverable. It will not re-download automatically. If you later want it again, you must re-fetch it deliberately from SD.")
        }
    }

    // MARK: - Active Deletions

    @ViewBuilder
    private var activeDeletionsSection: some View {
        let active = deletionIntents.filter { !$0.isTerminal }
        Section("In Progress") {
            ForEach(active) { intent in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(intent.bundleID.prefix(12))
                            .font(.caption.monospaced())
                        Text(intent.store == .ios ? "iOS" : "SD")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    DeletionPhaseBadge(phase: intent.phase)
                }
            }
        }
    }

    // MARK: - Tombstones

    @ViewBuilder
    private var tombstoneSection: some View {
        Section {
            ForEach(tombstones) { tombstone in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tombstone.bundleID.prefix(12))
                            .font(.caption.monospaced())
                        Text("Deleted \(tombstone.deletedAt.formatted(.relative(presentation: .named)))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await fetchAgain(bundleID: tombstone.bundleID) }
                    } label: {
                        Text("Fetch Again")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                }
            }
        } header: {
            Text("Tombstones")
        } footer: {
            Text("These recordings were deleted from this phone. They will not re-download automatically. Tap \"Fetch Again\" to re-download from the dongle.")
        }
    }

    // MARK: - Delete Actions

    @ViewBuilder
    private var deleteActionsSection: some View {
        Section {
            Button(role: .destructive) {
                showClearMirrorConfirm = true
            } label: {
                Label("Clear iOS Mirror", systemImage: "trash")
            }
        } header: {
            Text("Bulk Actions")
        }
        .confirmationDialog("Clear all iOS copies?", isPresented: $showClearMirrorConfirm) {
            Button("Clear All iOS Copies", role: .destructive) {
                Task { await clearIOSMirror() }
            }
        } message: {
            Text("All SD originals survive. All iPhone copies and tombstones are removed. This cannot be undone.")
        }
    }

    // MARK: - Helpers

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
        guard let store = reconciliationStore else {
            isLoading = false
            return
        }
        do {
            snapshot = try await store.latestSnapshot()
            deletionIntents = try await store.allDeletionIntents()
            tombstones = try await store.allTombstones()
        } catch {
            Self.log.error("Failed to load reconciliation state: \(error)")
        }
        isLoading = false
    }

    private func deleteIOSCopy(_ entry: ReconciliationEntry) async {
        guard let store = reconciliationStore else { return }
        let intent = DeletionIntent(bundleID: entry.bundleID, contentRoot: entry.contentRoot, store: .ios)
        do {
            try await store.createDeletionIntent(intent)
            try await store.updateDeletionPhase(id: intent.id, phase: .deleted, completedAt: Date())
            try await store.createTombstone(Tombstone(bundleID: entry.bundleID, contentRoot: entry.contentRoot))
            await load()
        } catch {
            Self.log.error("Failed to delete iOS copy \(entry.bundleID): \(error)")
        }
    }

    private func clearIOSMirror() async {
        guard let store = reconciliationStore, let snapshot else { return }
        let verified = snapshot.entries.filter { $0.state == .verified }
        for entry in verified {
            let intent = DeletionIntent(bundleID: entry.bundleID, contentRoot: entry.contentRoot, store: .ios)
            do {
                try await store.createDeletionIntent(intent)
                try await store.updateDeletionPhase(id: intent.id, phase: .deleted, completedAt: Date())
                try await store.createTombstone(Tombstone(bundleID: entry.bundleID, contentRoot: entry.contentRoot))
            } catch {
                Self.log.error("Failed to delete iOS copy \(entry.bundleID): \(error)")
            }
        }
        await load()
    }

    private func fetchAgain(bundleID: String) async {
        guard let store = reconciliationStore else { return }
        do {
            try await store.removeTombstone(bundleID: bundleID)
            await load()
        } catch {
            Self.log.error("Failed to remove tombstone for \(bundleID): \(error)")
        }
    }
}

// MARK: - Mirror State Badge

private struct MirrorStateBadge: View {
    let state: MirrorState

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch state {
        case .pending: "Pending"
        case .transferring: "Transferring"
        case .verified: "Verified"
        case .missing: "Missing"
        case .corrupt: "Corrupt"
        case .deletedIntentionally: "Deleted"
        }
    }

    private var color: Color {
        switch state {
        case .pending: .orange
        case .transferring: .blue
        case .verified: .green
        case .missing: .red
        case .corrupt: .red
        case .deletedIntentionally: .secondary
        }
    }
}

// MARK: - Deletion Phase Badge

private struct DeletionPhaseBadge: View {
    let phase: DeletionIntent.Phase

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch phase {
        case .toDelete: "Queued"
        case .deleting: "Deleting"
        case .deleted: "Done"
        case .failed: "Failed"
        }
    }

    private var color: Color {
        switch phase {
        case .toDelete: .orange
        case .deleting: .blue
        case .deleted: .green
        case .failed: .red
        }
    }
}
