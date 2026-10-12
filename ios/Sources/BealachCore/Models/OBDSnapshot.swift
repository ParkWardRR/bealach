import Foundation

/// An OBD-II diagnostic snapshot from a single poll cycle. Captures allowlisted
/// Mode 01/09 PIDs per the engine profile, with explicit sentinels for
/// unavailable values and honest error counts.
public struct OBDSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let timestamp: Date
    public let engineProfileID: String
    public let profileVersion: Int

    public var rpm: Int?
    public var speedKph: Int?
    public var coolantTempC: Int?
    public var intakeAirTempC: Int?
    public var mafGramsPerSec: Double?
    public var throttlePercent: Double?
    public var engineLoadPercent: Double?
    public var fuelPressureKPa: Int?
    public var timingAdvanceDeg: Double?
    public var lambdaRatio: Double?

    public var pidsRequested: UInt32
    public var pidsAnswered: UInt32
    public var cadenceMs: Int
    public var pidErrorCount: Int

    public init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        engineProfileID: String,
        profileVersion: Int,
        rpm: Int? = nil,
        speedKph: Int? = nil,
        coolantTempC: Int? = nil,
        intakeAirTempC: Int? = nil,
        mafGramsPerSec: Double? = nil,
        throttlePercent: Double? = nil,
        engineLoadPercent: Double? = nil,
        fuelPressureKPa: Int? = nil,
        timingAdvanceDeg: Double? = nil,
        lambdaRatio: Double? = nil,
        pidsRequested: UInt32 = 0,
        pidsAnswered: UInt32 = 0,
        cadenceMs: Int = 0,
        pidErrorCount: Int = 0
    ) {
        self.id = id
        self.timestamp = timestamp
        self.engineProfileID = engineProfileID
        self.profileVersion = profileVersion
        self.rpm = rpm
        self.speedKph = speedKph
        self.coolantTempC = coolantTempC
        self.intakeAirTempC = intakeAirTempC
        self.mafGramsPerSec = mafGramsPerSec
        self.throttlePercent = throttlePercent
        self.engineLoadPercent = engineLoadPercent
        self.fuelPressureKPa = fuelPressureKPa
        self.timingAdvanceDeg = timingAdvanceDeg
        self.lambdaRatio = lambdaRatio
        self.pidsRequested = pidsRequested
        self.pidsAnswered = pidsAnswered
        self.cadenceMs = cadenceMs
        self.pidErrorCount = pidErrorCount
    }

    public var answerRate: Double {
        guard pidsRequested > 0 else { return 0 }
        return Double(pidsAnswered.nonzeroBitCount) / Double(pidsRequested.nonzeroBitCount)
    }

    public var hasErrors: Bool { pidErrorCount > 0 }
}

/// Safety gate verdict for a single acceptance criterion from
/// vehicle-safety-and-power.md section 6.
public struct SafetyGateResult: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let gate: Gate
    public let passed: Bool
    public let detail: String
    public let testedAt: Date

    public init(
        id: String = UUID().uuidString,
        gate: Gate,
        passed: Bool,
        detail: String,
        testedAt: Date = Date()
    ) {
        self.id = id
        self.gate = gate
        self.passed = passed
        self.detail = detail
        self.testedAt = testedAt
    }

    public enum Gate: String, Codable, Sendable, Equatable, CaseIterable {
        case quietECU = "quiet-ecu"
        case missingSD = "missing-sd"
        case powerLossMidWrite = "power-loss-mid-write"
        case absentECU = "absent-ecu"
        case vehicleChange = "vehicle-change"
    }
}

/// Standby journal entry — matched pairs of sleep/wake events for parked
/// current attribution.
public struct StandbyJournalEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let enteredAt: Date
    public var exitedAt: Date?
    public let reason: WakeReason?
    public let batteryVAtEntry: Double?
    public let batteryVAtExit: Double?

    public init(
        id: String = UUID().uuidString,
        enteredAt: Date = Date(),
        exitedAt: Date? = nil,
        reason: WakeReason? = nil,
        batteryVAtEntry: Double? = nil,
        batteryVAtExit: Double? = nil
    ) {
        self.id = id
        self.enteredAt = enteredAt
        self.exitedAt = exitedAt
        self.reason = reason
        self.batteryVAtEntry = batteryVAtEntry
        self.batteryVAtExit = batteryVAtExit
    }

    public var durationSeconds: TimeInterval? {
        guard let exit = exitedAt else { return nil }
        return exit.timeIntervalSince(enteredAt)
    }

    public var isPaired: Bool { exitedAt != nil }

    public enum WakeReason: String, Codable, Sendable, Equatable {
        case motion
        case voltageThreshold = "voltage-threshold"
        case periodicHealth = "periodic-health"
        case bleConnection = "ble-connection"
    }
}
