import Foundation

/// Rules for when a phone-observed session starts and ends. Pure logic, no I/O.
public enum DriveSegmenter {
    /// A link gap longer than this closes the session. Short reconnects stay inside it.
    public static let gapThreshold: TimeInterval = 600 // 10 minutes

    /// Whether a gap that started at `droppedAt` has exceeded the threshold.
    public static func shouldClose(droppedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(droppedAt) >= gapThreshold
    }

    /// On app relaunch, decide what to do with an interrupted session.
    public static func reconcile(
        session: inout DriveSession,
        bleRestored: Bool,
        now: Date
    ) {
        switch session.lifecycle {
        case .active, .gapPending:
            let gap = now.timeIntervalSince(session.lastObservedAt)
            if bleRestored && gap < gapThreshold {
                session.lifecycle = .active
            } else if gap >= gapThreshold {
                session.lifecycle = .closed
                session.closedAt = session.lastObservedAt
                session.closeReason = .linkGap
            } else {
                session.lifecycle = .interrupted
            }
        case .interrupted:
            if shouldClose(droppedAt: session.lastObservedAt, now: now) {
                session.lifecycle = .closed
                session.closedAt = session.lastObservedAt
                session.closeReason = .appTerminatedDuringGap
            }
        case .closed:
            break
        }
    }
}
