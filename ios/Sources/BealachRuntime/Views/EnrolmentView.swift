import BealachCore
import SwiftUI

/// BLE-based enrolment flow: discover a dongle, confirm the fingerprint out-of-band, and
/// install owner keys. Replaces the server-based QR code setup.
public struct EnrolmentView: View {
    let bleManager: BealachBLEManager
    let enrolmentService: EnrolmentService
    let onComplete: () -> Void

    @State private var phase: Phase = .scanning
    @State private var discoveredFingerprint: String = ""
    @State private var discoveredDeviceID: Data = Data()
    @State private var userFingerprint: String = ""
    @State private var errorMessage: String?

    enum Phase {
        case scanning
        case confirmFingerprint
        case installing
        case success
        case failed(String)
    }

    public init(
        bleManager: BealachBLEManager,
        enrolmentService: EnrolmentService,
        onComplete: @escaping () -> Void
    ) {
        self.bleManager = bleManager
        self.enrolmentService = enrolmentService
        self.onComplete = onComplete
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                switch phase {
                case .scanning:
                    scanningView
                case .confirmFingerprint:
                    fingerprintView
                case .installing:
                    installingView
                case .success:
                    successView
                case .failed(let message):
                    failedView(message)
                }
            }
            .padding(24)
            .navigationTitle("Set Up Dongle")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }

    // MARK: - Scanning

    @ViewBuilder
    private var scanningView: some View {
        Spacer()
        ProgressView()
            .scaleEffect(1.5)
            .padding(.bottom, 16)
        Text("Searching for Dongle")
            .font(.title3.weight(.semibold))
        Text("Make sure your Bealach dongle is powered on and within range.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        Spacer()
    }

    // MARK: - Fingerprint Confirmation (E1)

    @ViewBuilder
    private var fingerprintView: some View {
        Spacer()
        Image(systemName: "checkmark.shield")
            .font(.system(size: 48))
            .foregroundStyle(.blue)
            .padding(.bottom, 8)

        Text("Confirm Identity")
            .font(.title3.weight(.semibold))

        Text("Check that this fingerprint matches the one shown on your dongle's serial label or provisioning receipt.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

        Text(formattedFingerprint(discoveredFingerprint))
            .font(.system(.title, design: .monospaced).weight(.bold))
            .kerning(4)
            .padding(.vertical, 16)
            .padding(.horizontal, 24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

        HStack(spacing: 16) {
            Button("Reject") {
                phase = .failed("Fingerprint was rejected. The dongle may not be the one you intended to pair with.")
            }
            .buttonStyle(.bordered)

            Button("Confirm & Pair") {
                phase = .installing
                Task { await installKeys() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.top, 8)

        Spacer()
    }

    // MARK: - Installing

    @ViewBuilder
    private var installingView: some View {
        Spacer()
        ProgressView()
            .scaleEffect(1.5)
            .padding(.bottom, 16)
        Text("Installing Owner Keys")
            .font(.title3.weight(.semibold))
        Text("Setting up the trust bond between this phone and your dongle.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        Spacer()
    }

    // MARK: - Success

    @ViewBuilder
    private var successView: some View {
        Spacer()
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 64))
            .foregroundStyle(.green)
            .padding(.bottom, 8)

        Text("Dongle Paired")
            .font(.title3.weight(.semibold))

        Text("Your Bealach dongle is now bonded to this phone. Recordings will be encrypted with your keys.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

        Button("Done") {
            onComplete()
        }
        .buttonStyle(.borderedProminent)
        .padding(.top, 16)
        Spacer()
    }

    // MARK: - Failed

    @ViewBuilder
    private func failedView(_ message: String) -> some View {
        Spacer()
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 48))
            .foregroundStyle(.orange)
            .padding(.bottom, 8)

        Text("Setup Failed")
            .font(.title3.weight(.semibold))

        Text(message)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

        HStack(spacing: 16) {
            Button("Retry") {
                phase = .scanning
            }
            .buttonStyle(.bordered)

            Button("Cancel") {
                onComplete()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.top, 16)
        Spacer()
    }

    // MARK: - Helpers

    private func formattedFingerprint(_ fp: String) -> String {
        let upper = fp.uppercased()
        guard upper.count == 8 else { return upper }
        let mid = upper.index(upper.startIndex, offsetBy: 4)
        return "\(upper[upper.startIndex..<mid]) \(upper[mid...])"
    }

    private func installKeys() async {
        do {
            let identity = EnrolledIdentity(
                deviceID: discoveredDeviceID,
                fingerprint: discoveredFingerprint,
                ownerKeyHex: ""
            )
            try await enrolmentService.enrol(identity: identity)
            NotificationCenter.default.post(name: .bealachSetupChanged, object: nil)
            phase = .success
        } catch {
            phase = .failed(DeviceEnrolment.message(for: error))
        }
    }
}
