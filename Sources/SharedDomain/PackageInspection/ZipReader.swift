// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Compression
import Foundation

/// Reads entries from a zip archive held in memory: stored and deflated
/// entries, which is what H5P and SCORM packages use. Anything else, or a
/// damaged archive, throws rather than guessing.
public struct ZipReader {
    public enum Failure: Error, Equatable {
        case notAZip, damaged, unsupportedMethod(Int), tooLarge
    }

    public struct Entry: Equatable {
        public let path: String
        let method: Int
        let compressedSize: Int
        let size: Int
        let localHeaderOffset: Int
    }

    /// Entries larger than this are never inflated, so a hostile archive
    /// can't exhaust memory in the previewer.
    public static let maxEntrySize = 32 * 1024 * 1024

    public let entries: [Entry]
    private let data: Data

    public init(data: Data) throws {
        self.data = data
        // The end of central directory record is in the last 64 KiB + 22 bytes.
        guard data.count >= 22 else { throw Failure.notAZip }
        let start = max(0, data.count - 65_557)
        var eocd: Int?
        var index = data.count - 22
        while index >= start {
            if Self.u32(data, index) == 0x0605_4B50 { eocd = index; break }
            index -= 1
        }
        guard let eocd else { throw Failure.notAZip }
        let count = Int(Self.u16(data, eocd + 10))
        var offset = Int(Self.u32(data, eocd + 16))
        var entries: [Entry] = []
        for _ in 0..<count {
            guard offset + 46 <= data.count, Self.u32(data, offset) == 0x0201_4B50 else { throw Failure.damaged }
            let method = Int(Self.u16(data, offset + 10))
            let compressed = Int(Self.u32(data, offset + 20))
            let size = Int(Self.u32(data, offset + 24))
            let nameLength = Int(Self.u16(data, offset + 28))
            let extraLength = Int(Self.u16(data, offset + 30))
            let commentLength = Int(Self.u16(data, offset + 32))
            let local = Int(Self.u32(data, offset + 42))
            guard offset + 46 + nameLength <= data.count else { throw Failure.damaged }
            let name = String(decoding: data[(data.startIndex + offset + 46)..<(data.startIndex + offset + 46 + nameLength)], as: UTF8.self)
            entries.append(Entry(path: name, method: method, compressedSize: compressed, size: size, localHeaderOffset: local))
            offset += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    public func entry(_ path: String) -> Entry? {
        entries.first { $0.path == path } ?? entries.first { $0.path.lowercased() == path.lowercased() }
    }

    public func contents(of entry: Entry) throws -> Data {
        guard entry.size <= Self.maxEntrySize, entry.compressedSize <= Self.maxEntrySize else { throw Failure.tooLarge }
        let header = entry.localHeaderOffset
        guard header + 30 <= data.count, Self.u32(data, header) == 0x0403_4B50 else { throw Failure.damaged }
        let begin = header + 30 + Int(Self.u16(data, header + 26)) + Int(Self.u16(data, header + 28))
        guard begin + entry.compressedSize <= data.count else { throw Failure.damaged }
        let raw = data[(data.startIndex + begin)..<(data.startIndex + begin + entry.compressedSize)]
        switch entry.method {
        case 0:
            return Data(raw)
        case 8:
            return try Self.inflate(Data(raw), size: entry.size)
        default:
            throw Failure.unsupportedMethod(entry.method)
        }
    }

    /// Raw DEFLATE, which is what Compression's zlib algorithm decodes.
    private static func inflate(_ input: Data, size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        // A damaged entry can claim content with no compressed bytes.
        guard !input.isEmpty else { throw Failure.damaged }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            input.withUnsafeBytes { source -> Int in
                guard let target = destination.bindMemory(to: UInt8.self).baseAddress,
                      let bytes = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(target, size, bytes, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw Failure.damaged }
        return output
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        let i = data.startIndex + offset
        return UInt16(data[i]) | UInt16(data[i + 1]) << 8
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
    }
}
