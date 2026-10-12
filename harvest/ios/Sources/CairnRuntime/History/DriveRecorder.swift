import CairnCore
import Foundation
import os

/// Records phone-observed sessions to the drive store. Consumes link events from `SessionState`
/// and location fixes from `DrivingSession`. Checkpoints on significant transitions and on the
/// existing 30 s summary timer. All writes go through the store actor.
@MainActor
public final class DriveRecorder {
    private static let log = Logger(subsystem: "app.cairn.companion", category: "recorder")
    private let store: any DriveStore
    private let vehicleStore: any VehicleStore
    private var current: DriveSession?
    private var lastCheckpoint: Date?
    private var gapStartedAt: Date?
    private var gapTimer: Task<Void, Never>?
    private var lastStreamingState = false
    private var streamingStart: Date?

    public init(store: any DriveStore, vehicleStore: any VehicleStore) {
        self.store = store
        self.vehicleStore = vehicleStore
    }

    // MARK: - Session lifecycle

    /// BLE link became ready. Start or resume a session.
    public func linkReady(deviceID: String?) {
        if var session = current, session.lifecycle == .gapPending {
            gapTimer?.cancel()
            gapTimer = nil
            gapStartedAt = nil
            session.lifecycle = .active
            session.reconnects += 1
            session.events.append(LinkEvent(at: Date(), kind: .ready))
            session.trackSegments.append(TrackSegment(startIndex: session.track.count, startedAt: Date()))
            current = session
            checkpoint()
        } else {
            let vid = resolveVehicleID(deviceID: deviceID)
            var session = DriveSession(deviceID: deviceID, vehicleID: vid, startedAt: Date())
            session.events.append(LinkEvent(at: Date(), kind: .ready))
            session.epochs.append(CounterEpoch(startedAt: Date()))
            current = session
            lastStreamingState = false
            streamingStart = nil
            checkpoint()
        }
    }

    private func resolveVehicleID(deviceID: String?) -> String? {
        if let deviceID, let assigned = try? vehicleStore.vehicleID(forDongle: deviceID) {
            return assigned
        }
        return vehicleStore.selectedVehicleID()
    }

    /// BLE link dropped. The session enters gap-pending; it closes if the gap exceeds the threshold.
    public func linkLost(reason: String?) {
        guard var session = current, session.lifecycle == .active else { return }
        let now = Date()
        session.lifecycle = .gapPending
        session.lastObservedAt = now
        session.events.append(LinkEvent(at: now, kind: .dropped, detail: reason))
        closeCurrentSegment(&session, at: now)
        accumulateStreaming(&session, at: now)
        current = session
        gapStartedAt = now
        checkpoint()
        startGapTimer()
    }

    /// User disarmed. Close the session immediately.
    public func disarmed() {
        guard var session = current else { return }
        let now = Date()
        session.events.append(LinkEvent(at: now, kind: .disarmed))
        closeCurrentSegment(&session, at: now)
        accumulateStreaming(&session, at: now)
        close(&session, at: now, reason: .disarmed)
        current = nil
        gapTimer?.cancel()
        gapTimer = nil
        gapStartedAt = nil
    }

    /// Retry exhausted or terminal failure.
    public func failed(reason: String) {
        guard var session = current else { return }
        let now = Date()
        session.events.append(LinkEvent(at: now, kind: .failed, detail: reason))
        closeCurrentSegment(&session, at: now)
        accumulateStreaming(&session, at: now)
        close(&session, at: now, reason: .retryExhausted)
        current = nil
        gapTimer?.cancel()
        gapTimer = nil
    }

    // MARK: - Data recording

    /// Called on each successful BLE write.
    public func recordSend() {
        guard current != nil else { return }
        current!.counters.sent += 1
    }

    /// Called when a fix is dropped (backpressure, encoding failure).
    public func recordWriteFailure() {
        guard current != nil else { return }
        current!.counters.writeFailures += 1
    }

    /// Called when COMPANION_STATUS arrives.
    public func recordStatus(_ status: CompanionStatus) {
        guard var session = current, let epoch = session.epochs.last else { return }
        session.counters.accumulate(from: epoch, status: status)
        session.lastObservedAt = Date()
        current = session
    }

    /// Called when streaming state changes.
    public func recordStreamingChange(isStreaming: Bool) {
        guard current != nil else { return }
        let now = Date()
        if isStreaming && !lastStreamingState {
            streamingStart = now
            current!.events.append(LinkEvent(at: now, kind: .streamingResumed))
        } else if !isStreaming && lastStreamingState {
            accumulateStreaming(&current!, at: now)
            current!.events.append(LinkEvent(at: now, kind: .streamingLost))
        }
        lastStreamingState = isStreaming
    }

    /// Called when an `OBD_LIVE` notification arrives for the first time in this session.
    public func noteOBDReceived() {
        guard var session = current, !session.obdReceived else { return }
        session.obdReceived = true
        current = session
    }

    /// Called when `DEVICE_STATUS` reports the dongle is driving.
    public func noteDeviceDriving() {
        guard var session = current, !session.deviceReportedDriving else { return }
        session.deviceReportedDriving = true
        current = session
    }

    /// Record a location fix to the track. Filters by accuracy.
    public func recordFix(_ fix: PhoneGNSSFix) {
        guard var session = current, session.lifecycle == .active else { return }
        guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= TrackPoint.maxAccuracy else { return }
        session.track.append(TrackPoint(fix: fix))
        session.lastObservedAt = fix.timestamp
        // Accumulate observed time: we are actively receiving location.
        if let last = lastCheckpoint {
            let delta = fix.timestamp.timeIntervalSince(last)
            if delta > 0 && delta < 5 { session.observedSeconds += delta }
        }
        current = session
    }

    /// Periodic checkpoint (call from the 30 s summary timer).
    public func checkpoint() {
        guard let session = current else { return }
        lastCheckpoint = Date()
        Task { [store, session] in
            do { try await store.save(session) }
            catch { Self.log.error("checkpoint failed: \(error)") }
        }
    }

    /// On app launch, reconcile any interrupted session.
    public func reconcileOnLaunch(bleRestored: Bool) {
        Task { [store] in
            do {
                var sessions = try await store.list()
                let now = Date()
                for i in sessions.indices where sessions[i].lifecycle != .closed {
                    DriveSegmenter.reconcile(session: &sessions[i], bleRestored: bleRestored, now: now)
                    try await store.save(sessions[i])
                }
            } catch {
                Self.log.error("reconcile failed: \(error)")
            }
        }
    }

    /// Start a new counter epoch for a new BLE connection.
    public func newCounterEpoch() {
        guard var session = current else { return }
        let prior = session.counters
        session.epochs.append(CounterEpoch(
            startedAt: Date(),
            priorAccepted: prior.accepted,
            priorRejected: prior.rejected,
            priorQueueDrops: prior.queueDrops
        ))
        current = session
    }

    /// All recorded sessions (for the History tab).
    public func allSessions() async throws -> [DriveSession] {
        try await store.list()
    }

    /// Sessions for a specific vehicle.
    public func sessions(forVehicle vehicleID: String) async throws -> [DriveSession] {
        try await store.list(vehicleID: vehicleID)
    }

    /// Sessions for the currently selected vehicle, or all if none selected.
    public func sessionsForSelectedVehicle() async throws -> [DriveSession] {
        if let vid = vehicleStore.selectedVehicleID() {
            return try await store.list(vehicleID: vid)
        }
        return try await store.list()
    }

    /// Delete a specific drive.
    public func deleteSession(_ id: UUID) async throws {
        if current?.id == id { current = nil }
        try await store.delete(id)
    }

    /// Delete all history. Stops any active recording.
    public func deleteAllSessions() async throws {
        current = nil
        gapTimer?.cancel()
        gapTimer = nil
        try await store.deleteAll()
    }

    // MARK: - Private

    private func startGapTimer() {
        gapTimer?.cancel()
        gapTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(DriveSegmenter.gapThreshold))
            guard !Task.isCancelled else { return }
            await self?.gapExpired()
        }
    }

    private func gapExpired() {
        guard var session = current, session.lifecycle == .gapPending else { return }
        close(&session, at: gapStartedAt ?? session.lastObservedAt, reason: .linkGap)
        current = nil
        gapStartedAt = nil
    }

    private func close(_ session: inout DriveSession, at date: Date, reason: DriveSession.CloseReason) {
        session.lifecycle = .closed
        session.closedAt = date
        session.closeReason = reason
        let final = session
        Task { [store] in
            do { try await store.save(final) }
            catch { Self.log.error("close save failed: \(error)") }
        }
    }

    private func closeCurrentSegment(_ session: inout DriveSession, at date: Date) {
        if var last = session.trackSegments.last, last.endIndex == nil {
            last.endIndex = session.track.count
            session.trackSegments[session.trackSegments.count - 1] = last
        }
    }

    private func accumulateStreaming(_ session: inout DriveSession, at now: Date) {
        if lastStreamingState, let start = streamingStart {
            session.streamingSeconds += now.timeIntervalSince(start)
            streamingStart = nil
        }
        lastStreamingState = false
    }
}
