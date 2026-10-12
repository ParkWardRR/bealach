// Provenance: cairn-ios-companion-app @ a7d02d8, Tests/CairnCoreTests/BundleOffloaderTests.swift
// Renamed Cairn* → Bealach* for Bealach.
// Rewritten for Bealach: server relay replaced with BundleSink local import.

import BealachCore
import CryptoKit
import Foundation
import Testing

// A model of the dongle (offload.md) and of the phone's local store (BundleSink),
// so the phone's whole loop runs without a radio or a network.

private func hex(_ data: some Sequence<UInt8>) -> String { data.map { String(format: "%02x", $0) }.joined() }
private func sha(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

private struct FakeBundle {
    let id: OffloadBundleID
    let stream: Data
    let chunkSize: Int
    var state: UInt8 = 0

    init(seed: UInt8, size: Int, chunkSize: Int = 1500, state: UInt8 = 0) {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = seed
        bytes[15] = 0xC1
        id = OffloadBundleID(bytes: Data(bytes))!
        stream = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
        self.chunkSize = chunkSize
        self.state = state
    }

    var chunks: [(offset: Int, length: Int, sha: String)] {
        stride(from: 0, to: stream.count, by: chunkSize).map { start in
            let end = min(start + chunkSize, stream.count)
            return (start, end - start, sha(stream[start..<end]))
        }
    }

    /// The fake manifest is JSON the sink understands; the phone treats it as opaque bytes.
    var manifest: Data {
        let rows = chunks.map { "[\($0.offset),\($0.length),\"\($0.sha)\"]" }.joined(separator: ",")
        return Data("{\"id\":\"\(id.hex)\",\"chunks\":[\(rows)]}".utf8)
    }
    var signature: Data { Data(repeating: 0xAB, count: 64) }
    static func receipt(for id: OffloadBundleID) -> Data { Data("RECEIPT:\(id.hex)".utf8) }
}

private final class FakeDongle: OffloadLink, @unchecked Sendable {
    let attMTU: Int
    let events: AsyncStream<OffloadWireEvent>
    private let continuation: AsyncStream<OffloadWireEvent>.Continuation
    private let lock = NSLock()

    private(set) var bundles: [FakeBundle]
    private(set) var pruned: [String] = []
    private(set) var reads: [String: Int] = [:]
    var tripActive = false
    var dropNextNotification = false
    var corruptBundles: Set<String> = []
    var receiptPolicy: (OffloadBundleID, Data) -> PutReceiptOutcome = { id, receipt in
        receipt == FakeBundle.receipt(for: id) ? .verifiedAndPruned : .rejectedSignature
    }
    var silent = false
    var vanishAfterNotifications: Int?
    private var notificationsSent = 0

    private struct PendingReceipt { var id: UInt8; var bundle: OffloadBundleID; var length: Int; var data = Data(); var nextSeq: UInt16 = 0 }
    private var receipt: PendingReceipt?

    init(bundles: [FakeBundle], mtu: Int = 247) {
        self.bundles = bundles
        self.attMTU = mtu
        var c: AsyncStream<OffloadWireEvent>.Continuation!
        events = AsyncStream { c = $0 }
        continuation = c
    }

    func disconnect() { continuation.yield(.disconnected); continuation.finish() }
    func readCount(_ id: OffloadBundleID) -> Int { lock.withLock { reads[id.hex] ?? 0 } }

    private var messageMax: Int { min(attMTU - 3, 244) }

    func writeControl(_ data: Data) async throws {
        if silent { return }
        lock.withLock { handle([UInt8](data)) }
    }

    func writeData(_ frames: [Data]) async throws {
        lock.withLock {
            guard var r = receipt else { return }
            for frame in frames {
                let f = try? OffloadDataFrame(decoding: frame)
                guard let f, f.sequence == r.nextSeq else { receipt = nil; indicate([0x84, r.id, 5]); return }
                r.data.append(f.bytes)
                r.nextSeq += 1
            }
            receipt = r
            guard r.data.count >= r.length else { return }
            receipt = nil
            let outcome = receiptPolicy(r.bundle, r.data)
            if outcome.bundleIsDone { pruned.append(r.bundle.hex); bundles.removeAll { $0.id == r.bundle } }
            indicate([0x84, r.id, 0, outcome.rawValue])
        }
    }

    // MARK: protocol

    private func indicate(_ bytes: [UInt8]) { continuation.yield(.indication(Data(bytes))) }

    private func handle(_ b: [UInt8]) {
        guard b.count >= 2 else { return }
        let op = b[0], id = b[1]
        if attMTU < OffloadReceiptFramer.minimumATTMTU { return indicate([op | 0x80, id, 5]) }
        switch op {
        case 0x01:
            if tripActive { return indicate([0x81, id, 4]) }
            let first = Int(b[2]) | Int(b[3]) << 8
            let perPage = (messageMax - 8) / 29
            let page = Array(bundles.dropFirst(first).prefix(perPage))
            var out: [UInt8] = [0x81, id, 0]
            out += le16(bundles.count) + le16(first) + [UInt8(page.count)]
            for e in page {
                out += [UInt8](e.id.bytes) + le64(e.stream.count) + le16(e.manifest.count) + le16(e.chunks.count) + [e.state]
            }
            indicate(out)
        case 0x02:
            guard !tripActive else { return indicate([0x82, id, 4]) }
            guard let bundle = bundle(b, at: 2) else { return indicate([0x82, id, 2]) }
            let payload = bundle.manifest + bundle.signature
            indicate([0x82, id, 0] + le32(payload.count))
            transfer(id, payload)
        case 0x03:
            guard !tripActive else { return indicate([0x83, id, 4]) }
            guard let bundle = bundle(b, at: 2) else { return indicate([0x83, id, 2]) }
            let offset = Int(le(b, 18, 8)), length = Int(le(b, 26, 4))
            guard offset + length <= bundle.stream.count else { return indicate([0x83, id, 3]) }
            reads[bundle.id.hex, default: 0] += 1
            var payload = Data(bundle.stream[offset..<offset + length])
            if corruptBundles.contains(bundle.id.hex), !payload.isEmpty { payload[0] ^= 0xFF }
            indicate([0x83, id, 0] + le32(length))
            transfer(id, payload)
        case 0x04:
            guard !tripActive else { return indicate([0x84, id, 4]) }
            guard let bundle = bundle(b, at: 2) else { return indicate([0x84, id, 2]) }
            let length = Int(le(b, 18, 2))
            guard length <= 1024 else { return indicate([0x84, id, 6]) }
            receipt = PendingReceipt(id: id, bundle: bundle.id, length: length)
            indicate([0x84, id, 0])
        case 0x05:
            indicate([0x85, id, 0])
        default:
            indicate([op | 0x80, id, 3])
        }
    }

    private func transfer(_ id: UInt8, _ payload: Data) {
        let room = messageMax - 2
        var seq: UInt16 = 0, offset = 0
        while offset < payload.count {
            let end = min(offset + room, payload.count)
            let frame = OffloadDataFrame(sequence: seq, bytes: payload[offset..<end]).encode()
            seq &+= 1
            offset = end
            if dropNextNotification { dropNextNotification = false; continue }
            notificationsSent += 1
            if let limit = vanishAfterNotifications, notificationsSent > limit { disconnect(); return }
            continuation.yield(.notification(frame))
        }
        indicate([0x86, id, 0] + le32(payload.count) + le32(Int(OffloadCRC32.checksum(payload))))
    }

    private func bundle(_ b: [UInt8], at i: Int) -> FakeBundle? {
        guard b.count >= i + 16, let id = OffloadBundleID(bytes: Data(b[i..<i + 16])) else { return nil }
        return bundles.first { $0.id == id }
    }
}

private func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
private func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
private func le64(_ v: Int) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * $0)) & 0xFF) } }
private func le(_ b: [UInt8], _ at: Int, _ n: Int) -> UInt64 { (0..<n).reduce(0) { $0 | UInt64(b[at + $1]) << (8 * UInt64($1)) } }

/// A fake local store that accepts bundles like a real BundleSink would.
/// It reads all offered chunks via the readChunk closure and produces a receipt.
private final class FakeSink: BundleSink, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var storedBundles: [String: Data] = [:]
    private(set) var chunkCounts: [String: Int] = [:]

    func importBundle(
        manifest: Data, signature: String,
        readChunk: @Sendable (Int64, Int64) async throws -> Data,
        onChunk: @Sendable (Int, Int, Int64) -> Void
    ) async throws -> BundleSinkResult {
        // Parse the manifest to get chunk offsets and the bundle ID.
        let json = try JSONSerialization.jsonObject(with: manifest) as! [String: Any]
        let bundleID = json["id"] as! String
        let chunks = json["chunks"] as! [[Any]]

        // If already stored, return immediately with no receipt.
        if lock.withLock({ storedBundles[bundleID] != nil }) {
            return BundleSinkResult(receipt: nil, chunksRead: 0, alreadyStored: true)
        }

        // Read each chunk.
        var data = Data()
        for (i, chunk) in chunks.enumerated() {
            let offset = Int64(chunk[0] as! Int)
            let length = Int64(chunk[1] as! Int)
            let expectedSha = chunk[2] as! String
            let chunkData = try await readChunk(offset, length)
            // Verify the chunk's integrity.
            let actualSha = hex(SHA256.hash(data: chunkData))
            guard actualSha == expectedSha else {
                return BundleSinkResult(receipt: nil, chunksRead: i, alreadyStored: false)
            }
            data.append(chunkData)
            onChunk(i + 1, chunks.count, Int64(chunkData.count))
        }

        // Store it and produce a receipt.
        let receipt = Data("RECEIPT:\(bundleID)".utf8)
        lock.withLock {
            storedBundles[bundleID] = data
            chunkCounts[bundleID] = chunks.count
        }
        return BundleSinkResult(
            receipt: OffloadReceipt(bytes: receipt),
            chunksRead: chunks.count,
            alreadyStored: false
        )
    }

    func data(for id: OffloadBundleID) -> Data? { lock.withLock { storedBundles[id.hex] } }
}

// MARK: - Harness

private func run(
    _ dongle: FakeDongle, _ sink: FakeSink, onProgress: @escaping @Sendable (OffloadProgress) -> Void = { _ in }
) async throws -> OffloadReport {
    let client = OffloadClient(link: dongle, timeout: .seconds(3))
    try await client.start()
    let report = await BundleOffloader(dongle: client, sink: sink).run(onProgress: onProgress)
    await client.stop()
    if ProcessInfo.processInfo.environment["OFFLOAD_DEBUG"] != nil { print("REPORT", report) }
    return report
}

@Suite struct BundleOffloaderTests {
    @Test func aDongleThatNeverAnswersTimesOutInsteadOfHanging() async throws {
        let dongle = FakeDongle(bundles: [FakeBundle(seed: 1, size: 100)])
        dongle.silent = true
        let client = OffloadClient(link: dongle, timeout: .milliseconds(150))
        try await client.start()
        let sink = FakeSink()
        let report = await BundleOffloader(dongle: client, sink: sink).run()
        await client.stop()
        guard case .linkLost(let why)? = report.stopped else { Issue.record("stopped: \(String(describing: report.stopped))"); return }
        #expect(why.contains("stopped answering"))
    }

    @Test func theSummaryIsPlainAndSaysWhenToWorry() {
        let ok = BundleOffloadResult(bundleID: "a", outcome: .done(.verifiedAndPruned), chunksRead: 2, bytes: 2_000_000)
        var report = OffloadReport(results: [ok, ok])
        #expect(report.summary.text.hasPrefix("Pulled 2 trips"))
        #expect(!report.summary.needsAttention)

        report.stopped = .tripActive
        #expect(report.summary.text.contains("recording a trip"))
        #expect(!report.summary.needsAttention)

        let rejected = OffloadReport(results: [.init(bundleID: "a", outcome: .dongleRejectedReceipt(.rejectedSignature), chunksRead: 1, bytes: 1)])
        #expect(rejected.summary.needsAttention)
        #expect(rejected.summary.text.contains("reflash"))

        #expect(OffloadReport(stopped: .nothingToOffload).summary.text.contains("no finished trips"))
    }

    @Test func pullsEveryBundleToLocalStoreAndReturnsReceipts() async throws {
        let a = FakeBundle(seed: 1, size: 5000), b = FakeBundle(seed: 2, size: 70_000, chunkSize: 66_000)
        let dongle = FakeDongle(bundles: [a, b]), sink = FakeSink()

        let report = try await run(dongle, sink)

        #expect(report.stopped == nil)
        #expect(report.results.map(\.outcome) == [.done(.verifiedAndPruned), .done(.verifiedAndPruned)])
        #expect(report.completed == 2)
        // The local store holds exactly the bytes that were on the dongle, and the dongle pruned both.
        #expect(sink.data(for: a.id) == a.stream)
        #expect(sink.data(for: b.id) == b.stream)
        #expect(Set(dongle.pruned) == [a.id.hex, b.id.hex])
        // A 66,000-byte chunk is more than one READ (64 KiB cap): the phone stitched two.
        #expect(dongle.readCount(b.id) >= 2)
        #expect(report.bytesImported == Int64(a.stream.count + b.stream.count))
    }

    @Test func nothingHappensWhileATripIsInProgress() async throws {
        let dongle = FakeDongle(bundles: [FakeBundle(seed: 1, size: 100)]), sink = FakeSink()
        dongle.tripActive = true
        let report = try await run(dongle, sink)
        #expect(report.stopped == .tripActive)
        #expect(report.results.isEmpty)
        #expect(dongle.pruned.isEmpty)
    }

    @Test func anEmptyDongleIsNotAnError() async throws {
        let report = try await run(FakeDongle(bundles: []), FakeSink())
        #expect(report.stopped == .nothingToOffload)
    }

    @Test func aBundleWithAVerifiedReceiptIsLeftForTheDongleToPrune() async throws {
        let dongle = FakeDongle(bundles: [FakeBundle(seed: 1, size: 100, state: 1)])
        let report = try await run(dongle, FakeSink())
        #expect(report.results.map(\.outcome) == [.alreadyReceipted])
        #expect(report.stopped == .nothingToOffload)
    }

    @Test func aLostNotificationIsReReadNotDiscarded() async throws {
        let a = FakeBundle(seed: 1, size: 3000, chunkSize: 3000)
        let dongle = FakeDongle(bundles: [a]), sink = FakeSink()
        dongle.dropNextNotification = true   // the dongle's CRC and length will not match what arrived

        let report = try await run(dongle, sink)

        #expect(report.results.map(\.outcome) == [.done(.verifiedAndPruned)])
        #expect(sink.data(for: a.id) == a.stream)
    }

    @Test func aForgedOrMismatchedReceiptStopsTheRunAndIsSurfaced() async throws {
        let a = FakeBundle(seed: 1, size: 100), b = FakeBundle(seed: 2, size: 100)
        let dongle = FakeDongle(bundles: [a, b]), sink = FakeSink()
        dongle.receiptPolicy = { _, _ in .rejectedContentRoot }

        let report = try await run(dongle, sink)

        #expect(report.results.map(\.outcome) == [.dongleRejectedReceipt(.rejectedContentRoot)])
        #expect(dongle.pruned.isEmpty)
    }

    @Test func aFirmwareWithoutAPinnedKeyIsReportedAndNothingIsDeleted() async throws {
        let a = FakeBundle(seed: 1, size: 100)
        let dongle = FakeDongle(bundles: [a])
        dongle.receiptPolicy = { _, _ in .noPinnedKey }
        let report = try await run(dongle, FakeSink())
        #expect(report.results.map(\.outcome) == [.dongleHasNoReceiptKey])
        #expect(dongle.pruned.isEmpty)
    }

    @Test func manyBundlesAreListedAcrossPages() async throws {
        let many = (0..<20).map { FakeBundle(seed: UInt8($0 + 1), size: 40) }
        let dongle = FakeDongle(bundles: many)
        let report = try await run(dongle, FakeSink())
        #expect(report.completed == 20)
        #expect(dongle.pruned.count == 20)
    }

    @Test func aLinkThatDropsMidTransferEndsTheRunWithoutDeletingAnything() async throws {
        let a = FakeBundle(seed: 1, size: 20_000, chunkSize: 20_000)
        let dongle = FakeDongle(bundles: [a])
        dongle.vanishAfterNotifications = 10
        let report = try await run(dongle, FakeSink())
        guard case .linkLost? = report.stopped else { Issue.record("stopped: \(String(describing: report.stopped))"); return }
        #expect(dongle.pruned.isEmpty)
    }

    @Test func aLinkBelowTheMinimumMTURefusesToStart() async throws {
        let client = OffloadClient(link: FakeDongle(bundles: [], mtu: 23))
        await #expect(throws: OffloadClientError.mtuTooSmall(23)) { try await client.start() }
    }

    @Test func progressNamesEachStepForTheScreen() async throws {
        let dongle = FakeDongle(bundles: [FakeBundle(seed: 1, size: 3000, chunkSize: 1000)])
        let seen = ProgressLog()
        _ = try await run(dongle, FakeSink(), onProgress: { seen.add($0) })
        let phases = seen.all.map(\.phase)
        #expect(phases.first == .listing)
        #expect(phases.contains(.fetchingManifest))
        #expect(phases.contains(.reading(chunk: 3, of: 3)))
        #expect(phases.last == .returningReceipt)
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [OffloadProgress] = []
    func add(_ p: OffloadProgress) { lock.withLock { items.append(p) } }
    var all: [OffloadProgress] { lock.withLock { items } }
}
