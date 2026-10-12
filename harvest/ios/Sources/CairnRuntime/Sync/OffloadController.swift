import CairnCore
import Foundation
import Observation
import os
#if os(iOS)
import UIKit
#endif

/// Carries the dongle's sealed bundles to the server (offload.md section 4) and tells the person
/// how it went. The phone is one uplink among several: a dongle with Wi-Fi or LTE may already have
/// delivered a bundle, and the loop copes (see `BundleOffloader`).
///
/// It runs by itself when the dongle becomes reachable, and again after a drive while the dongle
/// is still refusing because a trip is recording; `offloadNow()` is the manual button.
@MainActor
@Observable
public final class OffloadController {
    public enum Status: Equatable {
        case idle
        case running(String)
        case finished(String)
        case needsAttention(String)
    }

    private static let log = Logger(subsystem: "app.cairn.companion", category: "offload")
    private static let lastRunKey = "cairn.offload.lastRunAt"
    private static let retryInterval: Duration = .seconds(150)
    private static let maxRetries = 48   // about two hours of waiting for a drive to end

    public private(set) var status: Status = .idle
    public private(set) var progress: OffloadProgress?
    public private(set) var isRunning = false
    public private(set) var lastRunAt: Date?
    public private(set) var lastReport: OffloadReport?

    private let ble: CairnBLEManager
    private let sync: TripSyncClient
    private var retryTask: Task<Void, Never>?
    private var ranThisConnection = false

    public init(ble: CairnBLEManager, sync: TripSyncClient) {
        self.ble = ble
        self.sync = sync
        lastRunAt = UserDefaults.standard.object(forKey: Self.lastRunKey) as? Date
    }

    /// The dongle offers offload, a server is configured and the link is up.
    public var canOffload: Bool { ble.supportsBundleOffload && sync.hasServer }

    // MARK: Triggers

    public func offloadNow() {
        retryTask?.cancel()
        Task { await run(automatic: false) }
    }

    /// The dongle link became usable. Offload once per connection, a moment after it settles.
    public func dongleReady() {
        guard !ranThisConnection else { return }
        ranThisConnection = true
        Task {
            try? await Task.sleep(for: .seconds(3))
            await run(automatic: true)
        }
    }

    public func dongleLost() {
        ranThisConnection = false
        retryTask?.cancel()
        if !isRunning, case .running = status { status = .idle }
    }

    // MARK: The run

    private func run(automatic: Bool, attempt: Int = 0) async {
        guard !isRunning else { return }
        guard ble.supportsBundleOffload else {
            if !automatic { status = .needsAttention("The dongle isn't connected, or its firmware can't offload trips.") }
            return
        }
        guard sync.hasServer else {
            if !automatic { status = .needsAttention("Set up the server first: scan the setup QR code from the dashboard.") }
            return
        }

        isRunning = true
        progress = nil
        status = .running("Reaching the server…")
        let background = beginBackgroundTime()
        defer {
            isRunning = false
            progress = nil
            ble.closeOffloadLink()
            endBackgroundTime(background)
        }

        guard let (server, route) = await sync.makeServerClient() else {
            status = .needsAttention("Can't reach the server on the home network or Tailnet, or this phone isn't signed in. The dongle keeps its trips.")
            return
        }
        guard let link = ble.openOffloadLink() else {
            status = .needsAttention("Lost the connection to the dongle. Try again when it's back.")
            return
        }

        let client = OffloadClient(link: link)
        do { try await client.start() } catch {
            status = .needsAttention("The Bluetooth link is too slow to offload (MTU \(link.attMTU)). Reconnect to the dongle.")
            return
        }
        Self.log.notice("offload starting via \(route.rawValue)")
        status = .running("Asking the dongle what it has…")

        let offloader = BundleOffloader(dongle: client, relay: BundleRelayService(client: server))
        let report = await offloader.run { [weak self] progress in
            Task { @MainActor in self?.show(progress) }
        }
        await client.stop()

        lastReport = report
        lastRunAt = Date()
        UserDefaults.standard.set(lastRunAt, forKey: Self.lastRunKey)
        let summary = report.summary
        status = summary.needsAttention ? .needsAttention(summary.text) : .finished(summary.text)
        Self.log.notice("offload finished: \(summary.text)")

        if report.completed > 0 {
            // The server rebuilds its store after ingest; refresh History a little later.
            Task { try? await Task.sleep(for: .seconds(15)); sync.sync() }
        }
        if report.stopped == .tripActive || report.stopped == .dongleBusy, attempt < Self.maxRetries {
            scheduleRetry(attempt: attempt + 1)
        }
    }

    private func scheduleRetry(attempt: Int) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: Self.retryInterval)
            guard !Task.isCancelled else { return }
            await self?.run(automatic: true, attempt: attempt)
        }
    }

    private func show(_ p: OffloadProgress) {
        progress = p
        let of = p.bundles > 0 ? " (\(p.bundle) of \(p.bundles))" : ""
        switch p.phase {
        case .listing: status = .running("Asking the dongle what it has…")
        case .fetchingManifest: status = .running("Reading trip details\(of)…")
        case .uploading(let chunk, let total): status = .running("Sending trip data to the server\(of): part \(chunk) of \(total)…")
        case .returningReceipt: status = .running("Telling the dongle it's safe to free space\(of)…")
        }
    }

    // MARK: Background time

    #if os(iOS)
    private func beginBackgroundTime() -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: "cairn-offload")
    }

    private func endBackgroundTime(_ id: UIBackgroundTaskIdentifier) {
        if id != .invalid { UIApplication.shared.endBackgroundTask(id) }
    }
    #else
    private func beginBackgroundTime() -> Int { 0 }
    private func endBackgroundTime(_ id: Int) {}
    #endif
}
