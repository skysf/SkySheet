import Foundation

/// 在内存里拼一个 zip。条目按加入的顺序写，最后 `finished()` 补上中央目录。
///
/// xlsx 只需要最普通的 zip：不写 zip64、不加密、不写数据描述符（大小和 CRC 直接写在本地文件头里）。
public struct ZipWriter: Sendable {
    public enum Packing: Sendable {
        case store
        /// 压不小就自动改成 store。
        case deflate
    }

    private var body: [UInt8] = []
    private var directory: [UInt8] = []
    private var names: Set<String> = []
    private var count = 0

    public init() {}

    public mutating func addFile(
        _ name: String,
        contents: Data,
        packing: Packing = .deflate,
        modified: DOSDateTime = .earliest
    ) throws(ZipError) {
        let bytes = [UInt8](contents)
        let crc = CRC32.checksum(bytes)
        if packing == .deflate, let packed = Deflate.deflate(bytes) {
            try append(name, method: 8, crc: crc, payload: packed, uncompressedSize: bytes.count,
                       modified: modified, externalAttributes: 0)
        } else {
            try append(name, method: 0, crc: crc, payload: bytes, uncompressedSize: bytes.count,
                       modified: modified, externalAttributes: 0)
        }
    }

    /// 目录条目：名字以 "/" 结尾、没有内容。腾讯文档导出的 xlsx 里就有，照样能写回去。
    public mutating func addDirectory(_ name: String, modified: DOSDateTime = .earliest) throws(ZipError) {
        let directoryName = name.hasSuffix("/") ? name : name + "/"
        // 0x10：MS-DOS 的「目录」属性。
        try append(directoryName, method: 0, crc: 0, payload: [], uncompressedSize: 0,
                   modified: modified, externalAttributes: 0x10)
    }

    /// 整个 zip 的字节：已加入的条目 + 中央目录 + 中央目录结尾。
    public func finished() -> Data {
        var output = body
        output += directory
        output.appendLE32(0x0605_4B50)
        output.appendLE16(0)               // 这一卷的编号
        output.appendLE16(0)               // 中央目录所在的卷
        output.appendLE16(count)           // 这一卷的条目数
        output.appendLE16(count)           // 总条目数
        output.appendLE32(directory.count)
        output.appendLE32(body.count)      // 中央目录的起点
        output.appendLE16(0)               // 注释长度
        return Data(output)
    }

    private mutating func append(
        _ name: String,
        method: Int,
        crc: UInt32,
        payload: [UInt8],
        uncompressedSize: Int,
        modified: DOSDateTime,
        externalAttributes: Int
    ) throws(ZipError) {
        guard names.insert(name).inserted else { throw ZipError.duplicateEntry(name) }
        // 超过这些上限就得用 zip64，xlsx 到不了这么大。
        guard count < 0xFFFF, body.count + payload.count < 0xFFFF_FFFF, uncompressedSize < 0xFFFF_FFFF else {
            throw ZipError.unsupported("zip64")
        }
        let nameBytes = Array(name.utf8)
        // 第 11 位：名字是 UTF-8。只在真有非 ASCII 字符时才置，老工具更认。
        let flags = nameBytes.contains { $0 >= 0x80 } ? 0x0800 : 0
        let offset = body.count

        body.appendLE32(0x0403_4B50)
        body.appendLE16(20)                // 解压需要的版本 2.0
        body.appendLE16(flags)
        body.appendLE16(method)
        body.appendLE16(Int(modified.time))
        body.appendLE16(Int(modified.date))
        body.appendLE32(Int(crc))
        body.appendLE32(payload.count)
        body.appendLE32(uncompressedSize)
        body.appendLE16(nameBytes.count)
        body.appendLE16(0)                 // 附加字段长度
        body += nameBytes
        body += payload

        directory.appendLE32(0x0201_4B50)
        directory.appendLE16(20)           // 制作者：MS-DOS，2.0
        directory.appendLE16(20)
        directory.appendLE16(flags)
        directory.appendLE16(method)
        directory.appendLE16(Int(modified.time))
        directory.appendLE16(Int(modified.date))
        directory.appendLE32(Int(crc))
        directory.appendLE32(payload.count)
        directory.appendLE32(uncompressedSize)
        directory.appendLE16(nameBytes.count)
        directory.appendLE16(0)            // 附加字段长度
        directory.appendLE16(0)            // 注释长度
        directory.appendLE16(0)            // 起始卷
        directory.appendLE16(0)            // 内部属性
        directory.appendLE32(externalAttributes)
        directory.appendLE32(offset)
        directory += nameBytes
        count += 1
    }
}

private extension [UInt8] {
    mutating func appendLE16(_ value: Int) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8 & 0xFF))
    }

    mutating func appendLE32(_ value: Int) {
        appendLE16(value & 0xFFFF)
        appendLE16(value >> 16 & 0xFFFF)
    }
}
