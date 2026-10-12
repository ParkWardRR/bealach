import Foundation

public enum TarReader {
    public struct Entry: Sendable {
        public let name: String
        public let data: Data
    }

    public static func entries(from tar: Data) -> [Entry] {
        var results: [Entry] = []
        var offset = 0
        while offset + 512 <= tar.count {
            let header = tar[offset..<offset + 512]
            guard header.contains(where: { $0 != 0 }) else { break }

            let name = Self.string(header, at: 0, length: 100)
            let size = Self.octal(header, at: 124, length: 12)

            offset += 512
            guard size > 0, offset + size <= tar.count else {
                offset += Self.padded(size)
                continue
            }

            let fileData = tar[offset..<offset + size]
            results.append(Entry(name: name, data: Data(fileData)))
            offset += Self.padded(size)
        }
        return results
    }

    private static func string(_ data: Data, at offset: Int, length: Int) -> String {
        let slice = data[data.startIndex + offset ..< data.startIndex + offset + length]
        let bytes = slice.prefix(while: { $0 != 0 })
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func octal(_ data: Data, at offset: Int, length: Int) -> Int {
        let s = string(data, at: offset, length: length).trimmingCharacters(in: .whitespaces)
        return Int(s, radix: 8) ?? 0
    }

    private static func padded(_ size: Int) -> Int {
        (size + 511) & ~511
    }
}
