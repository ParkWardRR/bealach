import BealachCore
import Foundation
import Testing

@Suite struct OBDSnapshotTests {
    @Test func answerRateCalculation() {
        let snapshot = OBDSnapshot(
            engineProfileID: "n54", profileVersion: 1,
            pidsRequested: 0b1111, pidsAnswered: 0b1100
        )
        #expect(snapshot.answerRate == 0.5)
    }

    @Test func answerRateZeroWhenNoneRequested() {
        let snapshot = OBDSnapshot(
            engineProfileID: "n54", profileVersion: 1,
            pidsRequested: 0, pidsAnswered: 0
        )
        #expect(snapshot.answerRate == 0)
    }

    @Test func hasErrorsWhenPidErrorCountPositive() {
        let snapshot = OBDSnapshot(
            engineProfileID: "n54", profileVersion: 1,
            pidErrorCount: 3
        )
        #expect(snapshot.hasErrors)
    }

    @Test func noErrorsWhenPidErrorCountZero() {
        let snapshot = OBDSnapshot(engineProfileID: "n54", profileVersion: 1)
        #expect(!snapshot.hasErrors)
    }

    @Test func codableRoundTrip() throws {
        let snapshot = OBDSnapshot(
            engineProfileID: "m52tu", profileVersion: 2,
            rpm: 3200, speedKph: 85, coolantTempC: 92,
            mafGramsPerSec: 12.5, lambdaRatio: 0.998,
            pidsRequested: 0xFF, pidsAnswered: 0xFE,
            cadenceMs: 200, pidErrorCount: 1
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(OBDSnapshot.self, from: data)
        #expect(decoded == snapshot)
    }
}

@Suite struct SafetyGateResultTests {
    @Test func allGatesCovered() {
        #expect(SafetyGateResult.Gate.allCases.count == 5)
    }

    @Test func codableRoundTrip() throws {
        let result = SafetyGateResult(
            gate: .quietECU, passed: true,
            detail: "ECU silent for 23s; sensing continued; OBD errors recorded"
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(SafetyGateResult.self, from: data)
        #expect(decoded == result)
    }
}

@Suite struct StandbyJournalTests {
    @Test func pairedEntry() {
        let entry = StandbyJournalEntry(
            enteredAt: Date(timeIntervalSince1970: 1000),
            exitedAt: Date(timeIntervalSince1970: 1300),
            reason: .motion,
            batteryVAtEntry: 12.4,
            batteryVAtExit: 12.3
        )
        #expect(entry.isPaired)
        #expect(entry.durationSeconds == 300)
    }

    @Test func unpairedEntry() {
        let entry = StandbyJournalEntry(
            enteredAt: Date(),
            batteryVAtEntry: 12.6
        )
        #expect(!entry.isPaired)
        #expect(entry.durationSeconds == nil)
    }

    @Test func wakeReasonRoundTrip() throws {
        for reason in [StandbyJournalEntry.WakeReason.motion, .voltageThreshold, .periodicHealth, .bleConnection] {
            let entry = StandbyJournalEntry(reason: reason)
            let data = try JSONEncoder().encode(entry)
            let decoded = try JSONDecoder().decode(StandbyJournalEntry.self, from: data)
            #expect(decoded.reason == reason)
        }
    }
}
