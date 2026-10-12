// Provenance: cairn-ios-companion-app @ a7d02d8, Sources/CairnRuntime/Views/SettingsView.swift
// Renamed Cairn* → Bealach* for Bealach.
// Stripped server/dashboard/sync/identity sections — Bealach is pure BLE, no server.

import BealachCore
import SwiftUI
import UniformTypeIdentifiers

public struct SettingsView: View {
    let session: DrivingSession
    let dataPorter: DataPorter
    @State private var showDeleteConfirm = false
    @State private var showExportSheet = false
    @State private var showImportPicker = false
    @State private var exportPassphrase = ""
    @State private var importPassphrase = ""
    @State private var exportedFileURL: URL?
    @State private var showShareSheet = false
    @State private var importFileURL: URL?
    @State private var showImportPassphrase = false
    @State private var dataMessage: String?
    @State private var dataError: String?
    @State private var isExporting = false
    @State private var isImporting = false
    @AppStorage(FuelEstimate.ethanolKey) private var ethanol = FuelEstimate.defaultEthanolPercent

    let offload: OffloadController?
    let enrolmentService: EnrolmentService?
    @State private var showEnrolment = false

    public init(session: DrivingSession, dataPorter: DataPorter, offload: OffloadController? = nil, enrolmentService: EnrolmentService? = nil) {
        self.offload = offload
        self.session = session
        self.dataPorter = dataPorter
        self.enrolmentService = enrolmentService
    }

    public var body: some View {
        NavigationStack {
            Form {
                enrolmentSection
                deviceSection
                fuelSection
                bluetoothSection
                if let offload {
                    OffloadSection(offload: offload)
                }
                storageSection
                dataSection
                aboutSection
                dangerZone
            }
            .navigationTitle("Settings")
            .alert("Export", isPresented: $showExportSheet) {
                SecureField("Passphrase", text: $exportPassphrase)
                Button("Export") { performExport() }
                Button("Cancel", role: .cancel) { exportPassphrase = "" }
            } message: {
                Text("Enter a passphrase to encrypt the backup. You'll need it to restore.")
            }
            .alert("Import", isPresented: $showImportPassphrase) {
                SecureField("Passphrase", text: $importPassphrase)
                Button("Import") { performImport() }
                Button("Cancel", role: .cancel) { importPassphrase = ""; importFileURL = nil }
            } message: {
                Text("Enter the passphrase used when this backup was created.")
            }
            .alert("Done", isPresented: .init(get: { dataMessage != nil }, set: { if !$0 { dataMessage = nil } })) {
                Button("OK") { dataMessage = nil }
            } message: {
                Text(dataMessage ?? "")
            }
            .alert("Error", isPresented: .init(get: { dataError != nil }, set: { if !$0 { dataError = nil } })) {
                Button("OK") { dataError = nil }
            } message: {
                Text(dataError ?? "")
            }
            .fileImporter(isPresented: $showImportPicker, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        importFileURL = url
                        showImportPassphrase = true
                    }
                case .failure(let error):
                    dataError = error.localizedDescription
                }
            }
            #if os(iOS)
            .sheet(isPresented: $showShareSheet) {
                if let url = exportedFileURL {
                    ShareSheet(url: url)
                }
            }
            #endif
        }
    }

    // MARK: - Enrolment

    @ViewBuilder
    private var enrolmentSection: some View {
        if let enrolmentService {
            Section {
                Button {
                    showEnrolment = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "person.badge.key")
                            .font(.body)
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Dongle Enrolment")
                                .font(.body)
                            Text("Pair a new dongle or re-enrol")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            .sheet(isPresented: $showEnrolment) {
                EnrolmentView(
                    bleManager: session.ble,
                    enrolmentService: enrolmentService,
                    onComplete: { showEnrolment = false }
                )
            }
        }
    }

    // MARK: - Device

    @ViewBuilder
    private var deviceSection: some View {
        Section {
            NavigationLink {
                DeviceDetailView(state: session.state)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "cpu")
                        .font(.body)
                        .foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Device")
                            .font(.body)
                        Text("Firmware, identity, boot timing")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Fuel

    private var fuelSection: some View {
        Section {
            Stepper(value: $ethanol, in: 0...85) {
                HStack {
                    Text("Ethanol blend")
                    Spacer()
                    Text("E\(ethanol)").foregroundStyle(.secondary).monospacedDigit()
                }
            }
        } header: {
            Text("Fuel")
        } footer: {
            Text("What is in the tank, for the economy shown on each trip. The car's fuel rate is not read, so economy is estimated from airflow, and the blend changes the estimate.")
        }
    }

    // MARK: - Bluetooth

    @ViewBuilder
    private var bluetoothSection: some View {
        Section {
            NavigationLink {
                BluetoothSettingsView(session: session)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.body)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bluetooth")
                            .font(.body)
                        Text(session.state.stage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Storage

    @ViewBuilder
    private var storageSection: some View {
        Section {
            NavigationLink {
                StorageView(session: session, offload: offload)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "externaldrive")
                        .font(.body)
                        .foregroundStyle(.teal)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Storage & Mirror")
                            .font(.body)
                        Text("Bundles, reconciliation, SD state")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Data

    @ViewBuilder
    private var dataSection: some View {
        Section {
            Button {
                showExportSheet = true
            } label: {
                HStack {
                    Label("Export Data", systemImage: "square.and.arrow.up")
                    Spacer()
                    if isExporting { ProgressView() }
                }
            }
            .disabled(isExporting)

            Button {
                showImportPicker = true
            } label: {
                HStack {
                    Label("Import Data", systemImage: "square.and.arrow.down")
                    Spacer()
                    if isImporting { ProgressView() }
                }
            }
            .disabled(isImporting)
        } header: {
            Text("Data")
        } footer: {
            Text("Export creates an encrypted backup file containing vehicles, maintenance, odometer readings, and annotations.")
        }
    }

    private func performExport() {
        guard !exportPassphrase.isEmpty else {
            dataError = "Passphrase cannot be empty"
            return
        }
        isExporting = true
        let passphrase = exportPassphrase
        exportPassphrase = ""
        Task {
            do {
                let data = try await dataPorter.exportData(passphrase: passphrase)
                let fileName = "bealach-backup-\(Self.dateStamp()).bealachbackup"
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
                try data.write(to: tempURL)
                exportedFileURL = tempURL
                isExporting = false
                #if os(iOS)
                showShareSheet = true
                #else
                dataMessage = "Exported to \(tempURL.lastPathComponent)"
                #endif
            } catch {
                isExporting = false
                dataError = error.localizedDescription
            }
        }
    }

    private func performImport() {
        guard let url = importFileURL else { return }
        guard !importPassphrase.isEmpty else {
            dataError = "Passphrase cannot be empty"
            return
        }
        isImporting = true
        let passphrase = importPassphrase
        importPassphrase = ""
        Task {
            do {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                let summary = try await dataPorter.importData(data, passphrase: passphrase)
                isImporting = false
                importFileURL = nil
                dataMessage = "Imported \(summary.vehicles) vehicles, \(summary.maintenance) maintenance entries, \(summary.odometer) odometer readings, \(summary.annotations) annotations"
            } catch {
                isImporting = false
                importFileURL = nil
                dataError = error.localizedDescription
            }
        }
    }

    private static func dateStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    // MARK: - About

    @ViewBuilder
    private var aboutSection: some View {
        let build = BuildIdentity.current
        Section {
            LabeledContent("App", value: "Bealach")
            LabeledContent("Version", value: build.version)
            LabeledContent("Build", value: build.build)
            LabeledContent("Channel", value: build.channel.title)
            if let commit = build.commit {
                LabeledContent("Commit", value: commit)
            }
        } header: {
            Text("About")
        } footer: {
            if let notice = build.channel.notice {
                Text(notice)
            }
        }
    }

    // MARK: - Danger Zone

    @ViewBuilder
    private var dangerZone: some View {
        Section {
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("Delete All History", systemImage: "trash")
            }
            .confirmationDialog("Delete all drive history?", isPresented: $showDeleteConfirm) {
                Button("Delete All", role: .destructive) {
                    Task {
                        try? await session.recorder.deleteAllSessions()
                    }
                }
            } message: {
                Text("This removes all recorded sessions from this phone. This cannot be undone.")
            }

            Button {
                session.forgetDongle()
            } label: {
                Label("Forget Dongle", systemImage: "minus.circle")
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Danger Zone")
        }
    }
}

#if os(iOS)
private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif


/// "Trips on the dongle": what the phone is carrying, and a button to do it now.
private struct OffloadSection: View {
    let offload: OffloadController

    var body: some View {
        Section {
            HStack(spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(.subheadline.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            if offload.isRunning, let p = offload.progress, case .reading(let chunk, let total) = p.phase {
                ProgressView(value: Double(chunk), total: Double(max(total, 1)))
            }
            Button {
                offload.offloadNow()
            } label: {
                Label(offload.isRunning ? "Carrying trips…" : "Offload trips now", systemImage: "arrow.down.circle")
            }
            .disabled(offload.isRunning || !offload.canOffload)
        } header: {
            Text("Trips on the dongle")
        } footer: {
            Text("The dongle keeps each trip until confirmed received. If the dongle uploads some trips on its own, the phone only carries what is left.")
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch offload.status {
        case .running: Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.blue)
        case .finished: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .needsAttention: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .idle: Image(systemName: "externaldrive").foregroundStyle(.secondary)
        }
    }

    private var headline: String {
        switch offload.status {
        case .idle: offload.canOffload ? "Ready to carry trips" : "Not connected"
        case .running(let text), .finished(let text), .needsAttention(let text): text
        }
    }

    private var detail: String {
        if !offload.canOffload && offload.status == .idle {
            return "Connect to the dongle to carry its trips."
        }
        guard let when = offload.lastRunAt else { return "Hasn't run yet." }
        return "Last run \(when.formatted(.relative(presentation: .named)))."
    }
}
