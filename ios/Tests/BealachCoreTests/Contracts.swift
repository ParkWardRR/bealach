// Provenance: cairn-ios-companion-app @ a7d02d8, Tests/CairnCoreTests/Contracts.swift
// Renamed Cairn* → Bealach* for Bealach.

import Foundation

/// Where the pinned contracts live: `$CAIRN_CONTRACTS` if set (a contract and this app changing
/// together on a laptop), otherwise `.contracts/contracts` as fetched by scripts/fetch-contracts.sh
/// at the commit contracts.lock names. Nothing is vendored, so there is no copy to drift.
enum Contracts {
    static let root: URL = {
        if let override = ProcessInfo.processInfo.environment["CAIRN_CONTRACTS"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".contracts/contracts")
    }()

    static func data(_ path: String) throws -> Data {
        let url = root.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url) else {
            throw ContractsMissing(path: url.path)
        }
        return data
    }

    struct ContractsMissing: Error, CustomStringConvertible {
        let path: String
        var description: String { "missing \(path): run scripts/fetch-contracts.sh (or set CAIRN_CONTRACTS)" }
    }

    static func json(_ path: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data(path)) as! [String: Any]
    }
}

extension Data {
    init(hex: String) {
        precondition(hex.count % 2 == 0, "odd-length hex")
        var bytes = [UInt8](); bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
