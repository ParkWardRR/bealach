// Provenance: cairn-ios-companion-app @ a7d02d8, Sources/CairnCore/Models/TransmitThrottle.swift
// Renamed Cairn* → Bealach* for Bealach.

import Foundation

/// Holds the transmit cadence near 1 Hz. Core Location cadence is system-managed, so extra
/// fixes are dropped and gaps are tolerated. Works on measurement time, not arrival time.
public struct TransmitThrottle: Sendable {
    /// Slightly under 1 s so ordinary timestamp jitter does not skip a whole second.
    public var minInterval: TimeInterval
    private var lastSent: Date?

    public init(minInterval: TimeInterval = 0.9) {
        self.minInterval = minInterval
    }

    /// True if a sample at `timestamp` should be transmitted; records it as sent.
    /// Out-of-order and duplicate timestamps are dropped.
    public mutating func shouldSend(at timestamp: Date) -> Bool {
        if let lastSent, timestamp.timeIntervalSince(lastSent) < minInterval { return false }
        lastSent = timestamp
        return true
    }

    public mutating func reset() { lastSent = nil }
}
