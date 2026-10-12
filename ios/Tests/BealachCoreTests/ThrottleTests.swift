// Provenance: cairn-ios-companion-app @ a7d02d8, Tests/CairnCoreTests/ThrottleTests.swift
// Renamed Cairn* → Bealach* for Bealach.

import Foundation
import Testing
@testable import BealachCore

private func send(_ t: inout TransmitThrottle, at time: TimeInterval) -> Bool {
    t.shouldSend(at: Date(timeIntervalSince1970: 1_800_000_000 + time))
}

@Suite struct ThrottleTests {
    @Test func firstFixAlwaysSends() {
        var t = TransmitThrottle()
        #expect(send(&t, at: 0))
    }

    @Test func dropsFixesInsideTheInterval() {
        var t = TransmitThrottle()
        #expect(send(&t, at: 0))
        #expect(!send(&t, at: 0.3))
        #expect(!send(&t, at: 0.8))
        #expect(send(&t, at: 1.0))
    }

    @Test func dropFixDoesNotMoveTheWindow() {
        var t = TransmitThrottle()
        #expect(send(&t, at: 0))
        #expect(!send(&t, at: 0.5))
        #expect(send(&t, at: 0.95))
    }

    @Test func toleratesGaps() {
        var t = TransmitThrottle()
        #expect(send(&t, at: 0))
        #expect(send(&t, at: 7))
    }

    @Test func dropsOutOfOrderAndDuplicates() {
        var t = TransmitThrottle()
        #expect(send(&t, at: 5))
        #expect(!send(&t, at: 5))
        #expect(!send(&t, at: 3))
    }

    @Test func resetAllowsAnEarlierTimestamp() {
        var t = TransmitThrottle()
        #expect(send(&t, at: 5))
        t.reset()
        #expect(send(&t, at: 1))
    }
}
