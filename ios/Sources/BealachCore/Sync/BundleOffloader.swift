// Provenance: cairn-ios-companion-app @ a7d02d8, Sources/CairnCore/Sync/BundleOffloader.swift
// Renamed Cairn* → Bealach* for Bealach.

import CryptoKit
import Foundation

/// What happened to one bundle in an offload run.
public enum BundleOffloadOutcome: Equatable, Sendable {
    /// The bundle was pulled from the dongle and stored locally.
    case done(PutReceiptOutcome)
    /// The dongle already held a verified receipt for it (prune pending); nothing to do.
    case alreadyReceipted
    /// The receipt was carried back from a prior local import.
    case receiptCarriedBack(PutReceiptOutcome)
    /// The dongle refused the receipt. The signing key and the firmware's pinned key disagree.
    case dongleRejectedReceipt(PutReceiptOutcome)
    /// This firmware has no receipt key pinned: the bundle is safe, but the dongle will not free space.
    case dongleHasNoReceiptKey
    /// The bytes the dongle gave us did not match the offer's digest, even after re-reading.
    case corruptOnDongle(chunk: Int)
    case failed(String)
}

public struct BundleOffloadResult: Equatable, Sendable {
    public var bundleID: String
    public var outcome: BundleOffloadOutcome
    public var chunksRead: Int
    public var bytes: Int64

    public init(bundleID: String, outcome: BundleOffloadOutcome, chunksRead: Int, bytes: Int64) {
        self.bundleID = bundleID
        self.outcome = outcome
        self.chunksRead = chunksRead
        self.bytes = bytes
    }
}

public enum OffloadStop: Equatable, Sendable {
    /// A trip is in progress, so the dongle serves nothing. Try again after the drive.
    case tripActive
    /// Nothing sealed is waiting.
    case nothingToOffload
    /// The link dropped or timed out.
    case linkLost(String)
    case dongleBusy
}

public struct OffloadReport: Equatable, Sendable {
    public var results: [BundleOffloadResult]
    public var stopped: OffloadStop?

    public init(results: [BundleOffloadResult] = [], stopped: OffloadStop? = nil) {
        self.results = results
        self.stopped = stopped
    }

    public var completed: Int {
        results.filter {
            switch $0.outcome {
            case .done, .alreadyReceipted, .receiptCarriedBack: true
            default: false
            }
        }.count
    }
    public var bytesImported: Int64 { results.reduce(0) { $0 + $1.bytes } }
    public var problems: [BundleOffloadResult] {
        results.filter {
            switch $0.outcome {
            case .done, .alreadyReceipted, .receiptCarriedBack: false
            default: true
            }
        }
    }
}

extension OffloadReport {
    /// One plain sentence for the screen, and whether it needs the person's attention.
    public var summary: (text: String, needsAttention: Bool) {
        func trips(_ n: Int) -> String { n == 1 ? "1 trip" : "\(n) trips" }
        func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

        if results.contains(where: { Self.isRejection($0.outcome) }) {
            return ("The dongle refused the receipt, so it kept the trip. The signing key and the dongle's pinned key disagree: reflash the dongle with the correct receipt key.", true)
        }
        if results.contains(where: { $0.outcome == .dongleHasNoReceiptKey }) {
            return ("This dongle has no receipt key built in, so it can't free space after a pull. Flash a build that pins the receipt key.", true)
        }
        switch stopped {
        case .tripActive?:
            return ("The dongle is recording a trip. Trips are pulled after the drive.", false)
        case .dongleBusy?:
            return ("The dongle was busy. Trying again shortly.", false)
        case .linkLost(let why)?:
            return ("The connection to the dongle ended (\(why)). Nothing was lost; it carries on next time.", false)
        case .nothingToOffload? where completed == 0 && problems.isEmpty:
            return ("The dongle has no finished trips waiting.", false)
        default:
            break
        }
        var parts: [String] = []
        if completed > 0 { parts.append("Pulled \(trips(completed))\(bytesImported > 0 ? " (\(size(bytesImported)))" : "") from the dongle.") }
        let refused = problems.count
        if refused > 0 { parts.append("\(trips(refused)) could not be pulled: it stays on the dongle.") }
        return (parts.isEmpty ? "Done." : parts.joined(separator: " "), refused > 0)
    }

    fileprivate static func isRejection(_ outcome: BundleOffloadOutcome) -> Bool {
        if case .dongleRejectedReceipt = outcome { return true }
        return false
    }
}

public struct OffloadProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case listing
        case fetchingManifest
        case reading(chunk: Int, of: Int)
        case returningReceipt
    }
    public var phase: Phase
    /// 1-based position among the bundles this run will pull.
    public var bundle: Int
    public var bundles: Int
}

/// Receives bundles from a local import source and produces a receipt so the dongle can prune.
/// In Bealach the phone is the verified mirror: pull -> verify -> local import, no server relay.
public protocol BundleSink: Sendable {
    /// Import the manifest + data, return a receipt the dongle can verify.
    /// Throws on import failure; returns nil receipt when the bundle is already stored.
    func importBundle(
        manifest: Data, signature: String,
        readChunk: @Sendable (Int64, Int64) async throws -> Data,
        onChunk: @Sendable (Int, Int, Int64) -> Void
    ) async throws -> BundleSinkResult
}

public struct BundleSinkResult: Sendable {
    public var receipt: OffloadReceipt?
    public var chunksRead: Int
    public var alreadyStored: Bool

    public init(receipt: OffloadReceipt? = nil, chunksRead: Int = 0, alreadyStored: Bool = false) {
        self.receipt = receipt
        self.chunksRead = chunksRead
        self.alreadyStored = alreadyStored
    }
}

/// An opaque receipt the dongle verifies against its pinned key.
public struct OffloadReceipt: Sendable {
    public var bytes: Data
    public init(bytes: Data) { self.bytes = bytes }
}

/// Pulls sealed bundles from the dongle to the phone's local store.
///
/// This is the Bealach mirror engine: for every sealed bundle it reads the manifest,
/// pulls the data chunks to local storage, and carries a receipt back so the dongle
/// can free space. Every step is idempotent.
public actor BundleOffloader {
    private let dongle: OffloadClient
    private let sink: any BundleSink
    private let readSize: UInt32

    public init(dongle: OffloadClient, sink: any BundleSink, readSize: UInt32 = OffloadRequest.maximumReadLength) {
        self.dongle = dongle
        self.sink = sink
        self.readSize = min(readSize, OffloadRequest.maximumReadLength)
    }

    public func run(onProgress: @escaping @Sendable (OffloadProgress) -> Void = { _ in }) async -> OffloadReport {
        var report = OffloadReport()
        onProgress(.init(phase: .listing, bundle: 0, bundles: 0))

        let entries: [OffloadListEntry]
        do {
            entries = try await dongle.list()
        } catch {
            report.stopped = Self.stop(for: error)
            return report
        }
        let waiting = entries.filter { $0.state == .sealed }
        // Entries already holding a verified receipt are the dongle's to finish at boot.
        for entry in entries where entry.state == .receiptVerified {
            report.results.append(.init(bundleID: entry.bundleID.hex, outcome: .alreadyReceipted, chunksRead: 0, bytes: 0))
        }
        if waiting.isEmpty {
            report.stopped = .nothingToOffload
            return report
        }

        for (position, entry) in waiting.enumerated() {
            let number = position + 1
            do {
                let result = try await pull(entry, number: number, of: waiting.count, onProgress: onProgress)
                report.results.append(result)
                if result.outcome == .dongleHasNoReceiptKey || Self.isRejection(result.outcome) { break }
            } catch let error as OffloadClientError {
                report.stopped = Self.stop(for: error)
                return report
            } catch {
                report.results.append(.init(bundleID: entry.bundleID.hex, outcome: .failed("\(error)"), chunksRead: 0, bytes: 0))
            }
        }
        return report
    }

    // MARK: - One bundle

    private func pull(
        _ entry: OffloadListEntry, number: Int, of count: Int,
        onProgress: @escaping @Sendable (OffloadProgress) -> Void
    ) async throws -> BundleOffloadResult {
        onProgress(.init(phase: .fetchingManifest, bundle: number, bundles: count))
        let blob = try await dongle.manifest(entry.bundleID)
        let manifestLength = Int(entry.manifestLength)
        guard blob.count == manifestLength + 64 else {
            return .init(bundleID: entry.bundleID.hex,
                         outcome: .failed("manifest is \(blob.count) bytes, the dongle listed \(manifestLength) + 64"),
                         chunksRead: 0, bytes: 0)
        }
        let manifest = Data(blob.prefix(manifestLength))
        let signature = blob.suffix(64).map { String(format: "%02x", $0) }.joined()

        let counter = ByteCounter()
        let dongle = self.dongle
        let bundleID = entry.bundleID
        let readSize = self.readSize
        let result = try await sink.importBundle(
            manifest: manifest, signature: signature,
            readChunk: { offset, length in
                try await Self.readFromDongle(dongle: dongle, bundleID: bundleID, offset: offset, length: length, readSize: readSize)
            },
            onChunk: { done, total, bytes in
                counter.add(bytes)
                onProgress(.init(phase: .reading(chunk: done, of: total), bundle: number, bundles: count))
            })
        let importedBytes = counter.value

        guard let receipt = result.receipt else {
            // Already stored locally; nothing more to do.
            return .init(bundleID: entry.bundleID.hex, outcome: .alreadyReceipted, chunksRead: result.chunksRead, bytes: importedBytes)
        }

        onProgress(.init(phase: .returningReceipt, bundle: number, bundles: count))
        let outcome = try await dongle.putReceipt(entry.bundleID, receipt: receipt.bytes)
        let mapped: BundleOffloadOutcome
        switch outcome {
        case .verifiedAndPruned, .verifiedPruneIncomplete:
            mapped = result.alreadyStored ? .receiptCarriedBack(outcome) : .done(outcome)
        case .noPinnedKey:
            mapped = .dongleHasNoReceiptKey
        case .rejectedSignature, .rejectedContentRoot, .unknown:
            mapped = .dongleRejectedReceipt(outcome)
        }
        return .init(bundleID: entry.bundleID.hex, outcome: mapped, chunksRead: result.chunksRead, bytes: importedBytes)
    }

    // MARK: - Dongle reads

    private static func readFromDongle(
        dongle: OffloadClient, bundleID: OffloadBundleID,
        offset: Int64, length: Int64, readSize: UInt32
    ) async throws -> Data {
        var out = Data()
        out.reserveCapacity(Int(length))
        var position = UInt64(offset)
        var remaining = UInt64(length)
        while remaining > 0 {
            let want = UInt32(min(UInt64(readSize), remaining))
            let part = try await dongle.read(bundleID, offset: position, length: want)
            guard part.count == Int(want) else { throw OffloadClientError.protocolViolation("short READ") }
            out.append(part)
            position += UInt64(want)
            remaining -= UInt64(want)
        }
        return out
    }

    // MARK: - Classifying failures

    private static func isRejection(_ outcome: BundleOffloadOutcome) -> Bool {
        if case .dongleRejectedReceipt = outcome { return true }
        return false
    }

    private static func stop(for error: Error) -> OffloadStop {
        switch error {
        case OffloadClientError.refused(_, .tripActive): .tripActive
        case OffloadClientError.refused(_, .busy): .dongleBusy
        case OffloadClientError.disconnected: .linkLost("the dongle disconnected")
        case OffloadClientError.timedOut(let op): .linkLost("the dongle stopped answering \(op)")
        case OffloadClientError.mtuTooSmall(let mtu): .linkLost("the link's MTU of \(mtu) is too small for offload")
        default: .linkLost("\(error)")
        }
    }
}

private final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int64 = 0
    func add(_ n: Int64) { lock.withLock { total += n } }
    var value: Int64 { lock.withLock { total } }
}
