import CairnCore
import SwiftUI

/// Confirms a scanned `cairn://configure` code, then saves the server, trusts its CA and enrols
/// this device. Nothing is stored or sent until the person taps Connect, because the link can
/// come from anywhere.
struct ConfigureLinkSheet: View {
    let link: ConfigureLink
    let syncClient: TripSyncClient
    let enrolmentService: EnrolmentService?
    let onFinish: () -> Void

    private enum Phase: Equatable {
        case confirm
        case connecting
        case done
        case failed(String)
    }

    @State private var phase: Phase = .confirm
    @State private var alreadyEnrolled = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: icon)
                    .font(.system(size: 56))
                    .foregroundStyle(iconColor)
                    .padding(.top, 32)

                Text(title).font(.title2.weight(.semibold))

                switch phase {
                case .confirm, .connecting:
                    details
                case .done:
                    Text("This phone is enrolled with \(link.serverHost). Trips will sync when you are on the network.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.red)
                }

                Spacer()
                actions
            }
            .padding()
            .navigationTitle("Cairn Setup")
            .navigationBarTitleDisplayModeInline()
            .task {
                if let service = enrolmentService {
                    let (state, _) = await service.loadIdentity()
                    alreadyEnrolled = (state == .enrolled)
                }
                #if DEBUG
                if ProcessInfo.processInfo.environment["CAIRN_TEST_AUTOCONNECT"] != nil, !alreadyEnrolled { connect() }
                #endif
            }
        }
        .interactiveDismissDisabled(phase == .connecting)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Server", link.serverHost)
            if !link.tailnetURL.isEmpty, let host = URL(string: link.tailnetURL)?.host {
                row("Tailnet", host)
            }
            if link.caCertificateDER != nil {
                row("Certificate", "Trust this server's private CA for Cairn only")
            }
            row("Invitation", "Enrol this phone")
            if alreadyEnrolled {
                Text("This phone is already enrolled. Reset the identity in Settings first, then scan again.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch phase {
        case .confirm:
            Button("Connect") { connect() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(alreadyEnrolled || enrolmentService == nil)
            Button("Cancel", role: .cancel, action: onFinish)
        case .connecting:
            ProgressView("Connecting…")
        case .done:
            Button("Done", action: onFinish)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        case .failed:
            Button("Try again") { phase = .confirm }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Button("Close", role: .cancel, action: onFinish)
        }
    }

    private var title: String {
        switch phase {
        case .confirm, .connecting: "Connect to Cairn?"
        case .done: "Connected"
        case .failed: "Couldn't connect"
        }
    }

    private var icon: String {
        switch phase {
        case .confirm, .connecting: "qrcode.viewfinder"
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch phase {
        case .done: .green
        case .failed: .orange
        default: .accentColor
        }
    }

    private func connect() {
        guard let service = enrolmentService else { return }
        phase = .connecting
        Task {
            do {
                if let der = link.caCertificateDER { try PinnedCA.save(der: der) }
                syncClient.lanURL = link.serverURL
                if !link.tailnetURL.isEmpty { syncClient.tailnetURL = link.tailnetURL }
                NotificationCenter.default.post(name: .cairnSetupChanged, object: nil)
                _ = try await DeviceEnrolment.enrol(
                    code: link.invitationCode, serverURL: link.serverURL,
                    tailnetURL: syncClient.tailnetURL, service: service
                )
                phase = .done
                await syncClient.probeEndpoints()
                syncClient.sync()
            } catch {
                phase = .failed(failureMessage(error))
            }
        }
    }

    private func failureMessage(_ error: Error) -> String {
        if error is PinnedCA.SaveError {
            return "The certificate in this code is not valid. Ask for a new code."
        }
        return DeviceEnrolment.message(for: error)
    }
}

private extension View {
    @ViewBuilder
    func navigationBarTitleDisplayModeInline() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
