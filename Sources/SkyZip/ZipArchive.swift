import Foundation

/// 只读的 zip 包。整个文件读进内存（xlsx 一般只有几 MB），条目信息全部来自中央目录。
///
/// 只认普通 zip：stored 和 deflate 两种压缩方式，没有 zip64、没有加密。xlsx 用不到别的，
/// 遇到就明确报 `unsupported`，不去猜。
public struct ZipArchive: Sendable {
    /// 条目，顺序和中央目录里一致（保存时照这个顺序写回）。
    public let entries: [ZipEntry]
    private let bytes: [UInt8]
    private let indexByName: [String: Int]

    public init(data: Data) throws(ZipError) {
        let reader = LittleEndianBytes([UInt8](data))
        let end = try Self.endRecord(in: reader)
        var entries: [ZipEntry] = []
        entries.reserveCapacity(end.entryCount)
        var offset = end.directoryOffset
        for _ in 0..<end.entryCount {
            let (entry, next) = try Self.directoryEntry(at: offset, in: reader)
            entries.append(entry)
            offset = next
        }
        self.entries = entries
        self.bytes = reader.bytes
        // 同名条目（不合规的包）以第一个为准，和大多数解压工具一致。
        var index: [String: Int] = [:]
        for (position, entry) in entries.enumerated() where index[entry.name] == nil {
            index[entry.name] = position
        }
        self.indexByName = index
    }

    public func entry(named name: String) -> ZipEntry? {
        indexByName[name].map { entries[$0] }
    }

    /// 取一个条目解压后的内容，并核对 CRC。
    public func contents(of entry: ZipEntry) throws(ZipError) -> Data {
        let reader = LittleEndianBytes(bytes)
        let header = entry.localHeaderOffset
        guard try reader.u32(header) == 0x0403_4B50 else {
            throw ZipError.corrupt("missing local header for \(entry.name)")
        }
        // 数据起点要按本地文件头里的名字和附加字段长度算，它们可以和中央目录里的不一样。
        let start = header + 30 + (try reader.u16(header + 26)) + (try reader.u16(header + 28))
        let end = start + entry.compressedSize
        guard end <= bytes.count else { throw ZipError.truncated }

        let output: [UInt8]
        switch entry.method {
        case .stored:
            guard entry.compressedSize == entry.uncompressedSize else {
                throw ZipError.corrupt("stored entry \(entry.name) has mismatched sizes")
            }
            output = Array(bytes[start..<end])
        case .deflated:
            let result: Result<[UInt8], ZipError> = bytes.withUnsafeBytes { raw in
                Result { () throws(ZipError) -> [UInt8] in
                    try Deflate.inflate(UnsafeRawBufferPointer(rebasing: raw[start..<end]),
                                        expectedSize: entry.uncompressedSize)
                }
            }
            output = try result.get()
        case .other(let method):
            throw ZipError.unsupported("compression method \(method) in \(entry.name)")
        }
        guard CRC32.checksum(output) == entry.crc32 else {
            throw ZipError.corrupt("CRC mismatch in \(entry.name)")
        }
        return Data(output)
    }

    public func contents(ofEntryNamed name: String) throws(ZipError) -> Data? {
        guard let entry = entry(named: name) else { return nil }
        return try contents(of: entry)
    }

    // MARK: - 中央目录

    private struct EndRecord {
        let entryCount: Int
        let directoryOffset: Int
    }

    /// 从文件末尾往前找「中央目录结尾」：它后面最多跟 65535 字节的注释。
    private static func endRecord(in reader: LittleEndianBytes) throws(ZipError) -> EndRecord {
        let count = reader.bytes.count
        guard count >= 22 else { throw ZipError.notAZip }
        var offset = count - 22
        let lowest = max(0, count - 22 - 0xFFFF)
        while offset >= lowest {
            if try reader.u32(offset) == 0x0605_4B50,
               offset + 22 + (try reader.u16(offset + 20)) <= count {
                break
            }
            offset -= 1
        }
        guard offset >= lowest else { throw ZipError.notAZip }

        if offset >= 20, try reader.u32(offset - 20) == 0x0706_4B50 {
            throw ZipError.unsupported("zip64")
        }
        let entryCount = try reader.u16(offset + 10)
        let directoryOffset = try reader.u32(offset + 16)
        guard entryCount != 0xFFFF, directoryOffset != 0xFFFF_FFFF else {
            throw ZipError.unsupported("zip64")
        }
        return EndRecord(entryCount: entryCount, directoryOffset: directoryOffset)
    }

    private static func directoryEntry(at offset: Int, in reader: LittleEndianBytes) throws(ZipError) -> (ZipEntry, Int) {
        guard try reader.u32(offset) == 0x0201_4B50 else {
            throw ZipError.corrupt("bad central directory entry at \(offset)")
        }
        let flags = try reader.u16(offset + 8)
        let methodCode = try reader.u16(offset + 10)
        let compressedSize = try reader.u32(offset + 20)
        let uncompressedSize = try reader.u32(offset + 24)
        let nameLength = try reader.u16(offset + 28)
        let extraLength = try reader.u16(offset + 30)
        let commentLength = try reader.u16(offset + 32)
        let localHeaderOffset = try reader.u32(offset + 42)
        let name = String(decoding: try reader.slice(offset + 46, count: nameLength), as: UTF8.self)

        guard flags & 1 == 0 else { throw ZipError.unsupported("encrypted entry \(name)") }
        guard compressedSize != 0xFFFF_FFFF, uncompressedSize != 0xFFFF_FFFF, localHeaderOffset != 0xFFFF_FFFF else {
            throw ZipError.unsupported("zip64")
        }
        let method: ZipEntry.Method = switch methodCode {
        case 0: .stored
        case 8: .deflated
        default: .other(methodCode)
        }
        let entry = ZipEntry(
            name: name,
            method: method,
            crc32: UInt32(try reader.u32(offset + 16)),
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize,
            modified: DOSDateTime(time: UInt16(try reader.u16(offset + 12)), date: UInt16(try reader.u16(offset + 14))),
            localHeaderOffset: localHeaderOffset
        )
        return (entry, offset + 46 + nameLength + extraLength + commentLength)
    }
}

/// 按小端序读 zip 的字段。越界一律算文件被截断。
struct LittleEndianBytes {
    let bytes: [UInt8]

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    func u16(_ offset: Int) throws(ZipError) -> Int {
        guard offset >= 0, offset + 2 <= bytes.count else { throw ZipError.truncated }
        return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
    }

    func u32(_ offset: Int) throws(ZipError) -> Int {
        try u16(offset) | (try u16(offset + 2)) << 16
    }

    func slice(_ offset: Int, count: Int) throws(ZipError) -> ArraySlice<UInt8> {
        guard offset >= 0, count >= 0, offset + count <= bytes.count else { throw ZipError.truncated }
        return bytes[offset..<offset + count]
    }
}
