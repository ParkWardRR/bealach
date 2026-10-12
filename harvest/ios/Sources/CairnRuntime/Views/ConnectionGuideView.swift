import SwiftUI

struct ConnectionGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Getting Started") {
                    step("1", "Power on the Cairn dongle")
                    step("2", "Toggle **Auto-connect** on in this app")
                    step("3", "Enter the 6-digit passkey when iOS prompts")
                    step("4", "Status shows **Streaming** once GPS data is flowing")
                }

                Section("What the Status Means") {
                    indicator("Streaming", .green,
                             "Connected — GPS fixes are being sent and acknowledged")
                    indicator("Bonded", .green,
                             "Link established, waiting for first device response")
                    indicator("Connected, no data", .orange,
                             "Link up but the device hasn't responded recently")
                    indicator("Connecting", .orange,
                             "Searching for or reconnecting to the dongle")
                    indicator("Stale pairing", .red,
                             "The dongle's bond keys changed (e.g. after a reflash). Re-pair needed")
                }

                Section("Re-pairing from Scratch") {
                    step("1", "Toggle **Auto-connect** off")
                    step("2", "Open **Settings → Bluetooth → Cairn → Forget This Device**")
                    step("3", "Power-cycle the dongle")
                    step("4", "Toggle **Auto-connect** back on and enter the passkey")
                }

                Section {
                    trouble("Dongle not found",
                            "Make sure it's powered on and within ~10 m. The app scans by service UUID, so the dongle must be advertising.")
                    trouble("Passkey rejected",
                            "Check that you entered the correct 6-digit code. The passkey is compiled into the dongle firmware.")
                    trouble("Stale pairing",
                            "The dongle was reflashed or had its bond cleared. Tap \"Forget Dongle\" in the app, then also forget in iOS Bluetooth settings before reconnecting.")
                    trouble("Frequent disconnects",
                            "Brief BLE drops during a drive are normal — the app reconnects automatically with backoff. Stay within range (~10 m line-of-sight).")
                    trouble("No data after connecting",
                            "The dongle may still be acquiring a GPS fix after a cold start. Wait 30–60 s for satellites.")
                    trouble("Location permission",
                            "The app needs \"Always\" location access to stream GPS when the screen is locked. Check Settings → Cairn → Location.")
                } header: {
                    Text("Troubleshooting")
                }
            }
            .navigationTitle("Connection Guide")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func step(_ number: String, _ text: LocalizedStringKey) -> some View {
        Label { Text(text) } icon: {
            Image(systemName: "\(number).circle.fill")
                .foregroundStyle(Color.accentColor)
        }
        .font(.subheadline)
    }

    private func indicator(_ name: String, _ color: Color, _ desc: String) -> some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline.weight(.medium))
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func trouble(_ title: String, _ solution: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.medium))
            Text(solution).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
