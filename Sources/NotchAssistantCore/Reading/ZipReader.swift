import Compression
import Foundation

/// Reads files out of a .zip (Word, PowerPoint and Excel documents are zip
/// packages of XML). Read-only, in memory, stored or deflated entries only:
/// no shelling out to `unzip`.
struct ZipReader {
    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let size: Int
        let localHeaderOffset: Int
    }

    let data: Data
    let entries: [String: Entry]

    /// Nil when it isn't a zip or its directory is unreadable.
    init?(data: Data) {
        self.data = data
        guard let entries = Self.centralDirectory(data) else { return nil }
        self.entries = entries
    }

    var names: [String] { Array(entries.keys) }

    /// An entry's bytes, inflated; nil if missing, too large or unsupported.
    func file(_ name: String, limit: Int = 50_000_000) -> Data? {
        guard let entry = entries[name], entry.size <= limit else { return nil }
        let header = entry.localHeaderOffset
        guard header + 30 <= data.count, u32(header) == 0x04034b50 else { return nil }
        let start = header + 30 + Int(u16(header + 26)) + Int(u16(header + 28))
        guard start + entry.compressedSize <= data.count else { return nil }
        let compressed = data.subdata(in: start..<start + entry.compressedSize)
        switch entry.method {
        case 0: return compressed
        case 8: return Self.inflate(compressed, size: entry.size)
        default: return nil
        }
    }

    private func u16(_ offset: Int) -> UInt16 { Self.u16(data, offset) }
    private func u32(_ offset: Int) -> UInt32 { Self.u32(data, offset) }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[data.startIndex + offset]) | UInt16(data[data.startIndex + offset + 1]) << 8
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[data.startIndex + offset + $1]) << (8 * UInt32($1)) }
    }

    private static func centralDirectory(_ data: Data) -> [String: Entry]? {
        // The end-of-central-directory record is in the last 64 KB + 22 bytes.
        guard data.count >= 22 else { return nil }
        let lowest = max(0, data.count - 65_557)
        var end = data.count - 22
        while end >= lowest, u32(data, end) != 0x06054b50 { end -= 1 }
        guard end >= lowest else { return nil }
        let count = Int(u16(data, end + 10))
        var offset = Int(u32(data, end + 16))
        var entries: [String: Entry] = [:]
        for _ in 0..<count {
            guard offset + 46 <= data.count, u32(data, offset) == 0x02014b50 else { return nil }
            let nameLength = Int(u16(data, offset + 28))
            let extraLength = Int(u16(data, offset + 30))
            let commentLength = Int(u16(data, offset + 32))
            guard offset + 46 + nameLength <= data.count else { return nil }
            let nameData = data.subdata(in: offset + 46..<offset + 46 + nameLength)
            let name = String(decoding: nameData, as: UTF8.self)
            entries[name] = Entry(
                name: name,
                method: u16(data, offset + 10),
                compressedSize: Int(u32(data, offset + 20)),
                size: Int(u32(data, offset + 24)),
                localHeaderOffset: Int(u32(data, offset + 42))
            )
            offset += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// Raw DEFLATE (what zip uses), through Apple's Compression framework.
    private static func inflate(_ compressed: Data, size: Int) -> Data? {
        guard size > 0 else { return Data() }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { destination in
            compressed.withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, size,
                    source.bindMemory(to: UInt8.self).baseAddress!, compressed.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        return written == size ? output : nil
    }
}
