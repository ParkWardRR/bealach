import BealachCore
import SwiftUI

public struct DiagnosticsView: View {
    let session: DrivingSession
    @State private var snapshots: [OBDSnapshot] = []
    @State private var safetyResults: [SafetyGateResult] = []
    @State private var standbyEntries: [StandbyJournalEntry] = []
    @State private var isLoading = true

    public init(session: DrivingSession) {
        self.session = session
    }

    public var body: some View {
        List {
            obdSection
            safetySection
            standbySection
        }
        .navigationTitle("Diagnostics")
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: - OBD

    @ViewBuilder
    private var obdSection: some View {
        Section {
            if snapshots.isEmpty {
                Label("No OBD data yet", systemImage: "car.side")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshots.prefix(10)) { snapshot in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(snapshot.engineProfileID)
                                .font(.caption.monospaced().weight(.semibold))
                            Text("v\(snapshot.profileVersion)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(snapshot.timestamp, style: .time)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                            if let rpm = snapshot.rpm {
                                obdTile("RPM", "\(rpm)")
                            }
                            if let speed = snapshot.speedKph {
                                obdTile("Speed", "\(speed) km/h")
                            }
                            if let temp = snapshot.coolantTempC {
                                obdTile("Coolant", "\(temp) C")
                            }
                            if let maf = snapshot.mafGramsPerSec {
                                obdTile("MAF", String(format: "%.1f g/s", maf))
                            }
                            if let throttle = snapshot.throttlePercent {
                                obdTile("Throttle", String(format: "%.0f%%", throttle))
                            }
                            if let load = snapshot.engineLoadPercent {
                                obdTile("Load", String(format: "%.0f%%", load))
                            }
                        }
                        HStack(spacing: 12) {
                            Label(String(format: "%.0f%% answered", snapshot.answerRate * 100), systemImage: "checkmark.circle")
                                .font(.caption2)
                                .foregroundStyle(snapshot.answerRate >= 0.8 ? .green : .orange)
                            if snapshot.hasErrors {
                                Label("\(snapshot.pidErrorCount) errors", systemImage: "exclamationmark.triangle")
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                            }
                            Text("\(snapshot.cadenceMs) ms")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        } header: {
            Text("OBD Snapshots")
        } footer: {
            Text("Read-only diagnostic snapshots from the allowlisted engine profile. The dongle never sends write commands.")
        }
    }

    @ViewBuilder
    private func obdTile(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.caption.monospacedDigit().weight(.medium))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Safety Gates

    @ViewBuilder
    private var safetySection: some View {
        Section {
            if safetyResults.isEmpty {
                Label("No safety tests recorded", systemImage: "shield")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(safetyResults) { result in
                    HStack {
                        Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result.passed ? .green : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(gateLabel(result.gate))
                                .font(.subheadline)
                            Text(result.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(result.testedAt, style: .date)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            HStack {
                Text("Safety Gates")
                Spacer()
                if !safetyResults.isEmpty {
                    let allPassed = safetyResults.allSatisfy(\.passed)
                    Text(allPassed ? "All Pass" : "Attention")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(allPassed ? .green : .red)
                }
            }
        } footer: {
            Text("Acceptance criteria from vehicle-safety-and-power.md section 6. Each gate must pass on hardware before Phase 2 is complete.")
        }
    }

    private func gateLabel(_ gate: SafetyGateResult.Gate) -> String {
        switch gate {
        case .quietECU: "Quiet ECU"
        case .missingSD: "Missing/Failed SD"
        case .powerLossMidWrite: "Power Loss Mid-Write"
        case .absentECU: "Absent ECU (Bench)"
        case .vehicleChange: "Vehicle Change"
        }
    }

    // MARK: - Standby Journal

    @ViewBuilder
    private var standbySection: some View {
        Section {
            if standbyEntries.isEmpty {
                Label("No standby events recorded", systemImage: "moon.zzz")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(standbyEntries.prefix(20)) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Image(systemName: entry.isPaired ? "arrow.left.arrow.right" : "arrow.right")
                                    .font(.caption)
                                    .foregroundStyle(entry.isPaired ? .green : .orange)
                                Text(entry.enteredAt, style: .time)
                                    .font(.caption.monospacedDigit())
                                if let dur = entry.durationSeconds {
                                    Text(formatDuration(dur))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            HStack(spacing: 8) {
                                if let v = entry.batteryVAtEntry {
                                    Text(String(format: "%.1f V in", v))
                                        .font(.caption2)
                                        .foregroundStyle(v < 11.5 ? .orange : .secondary)
                                }
                                if let v = entry.batteryVAtExit {
                                    Text(String(format: "%.1f V out", v))
                                        .font(.caption2)
                                        .foregroundStyle(v < 11.5 ? .orange : .secondary)
                                }
                                if let reason = entry.reason {
                                    Text(wakeLabel(reason))
                                        .font(.caption2)
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        Spacer()
                    }
                }
            }
        } header: {
            Text("Standby Journal")
        } footer: {
            Text("Matched sleep/wake pairs for parked current attribution. Unpaired entries indicate an ongoing or interrupted standby cycle.")
        }
    }

    private func wakeLabel(_ reason: StandbyJournalEntry.WakeReason) -> String {
        switch reason {
        case .motion: "Motion"
        case .voltageThreshold: "Voltage"
        case .periodicHealth: "Health tick"
        case .bleConnection: "BLE"
        }
    }

    private func formatDuration(_ s: TimeInterval) -> String {
        let m = Int(s) / 60
        let sec = Int(s) % 60
        if m > 0 { return "\(m)m \(sec)s" }
        return "\(sec)s"
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        if let live = session.state.obdLive {
            let engine = session.ble.lastDeviceInfo?.engines.first
            snapshots = [OBDSnapshot(
                timestamp: session.state.lastOBDAt ?? Date(),
                engineProfileID: engine?.engineID ?? "live",
                profileVersion: Int(engine?.profileVersion ?? 0),
                rpm: live.rpm == OBDLiveSnapshot.invalidU16 ? nil : Int(live.rpm),
                speedKph: live.speedKph.map { Int($0) },
                coolantTempC: live.coolantTempC == OBDLiveSnapshot.invalidI16 ? nil : Int(live.coolantTempC),
                intakeAirTempC: live.intakeTempC == OBDLiveSnapshot.invalidI16 ? nil : Int(live.intakeTempC),
                mafGramsPerSec: live.maf,
                throttlePercent: live.throttlePct == 0xFF ? nil : Double(live.throttlePct),
                engineLoadPercent: live.engineLoadPct == 0xFF ? nil : Double(live.engineLoadPct),
                fuelPressureKPa: live.fuelPressureKpa == OBDLiveSnapshot.invalidU16 ? nil : Int(live.fuelPressureKpa),
                timingAdvanceDeg: live.timingAdv
            )]
        }
        isLoading = false
    }
}
