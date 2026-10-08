import Foundation

/// zip 用的 CRC-32（IEEE 802.3 多项式，反射形式 0xEDB88320）。
/// 系统的 Compression 只管压缩不管校验，zlib 又要另配模块映射，自己写二十行最省事（设计第 7 条）。
public enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var c = UInt32(index)
        for _ in 0..<8 {
            c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    public static func checksum(_ bytes: UnsafeRawBufferPointer) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        table.withUnsafeBufferPointer { table in
            for byte in bytes {
                c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
            }
        }
        return c ^ 0xFFFF_FFFF
    }

    public static func checksum(_ bytes: [UInt8]) -> UInt32 {
        bytes.withUnsafeBytes { checksum($0) }
    }

    public static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { checksum($0) }
    }
}
