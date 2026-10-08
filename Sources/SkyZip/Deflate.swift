import Compression
import Foundation

/// zip 里的 deflate 数据就是不带头尾的原始 DEFLATE（RFC 1951）。
/// 系统 Compression 的 `COMPRESSION_ZLIB` 正好是这种格式（不带 zlib 头），可以直接用（2026-10-08 实测解开了样例里的条目）。
enum Deflate {
    /// 解压。`expectedSize` 来自中央目录；解出来的长度对不上就算损坏。
    static func inflate(_ source: UnsafeRawBufferPointer, expectedSize: Int) throws(ZipError) -> [UInt8] {
        guard expectedSize > 0 else { return [] }
        guard let base = source.baseAddress?.assumingMemoryBound(to: UInt8.self), !source.isEmpty else {
            throw ZipError.corrupt("empty deflate stream")
        }
        // 多给一个字节：解出来的比中央目录说的长，会把缓冲区写满，好认出来。
        var output = [UInt8](repeating: 0, count: expectedSize + 1)
        let written = output.withUnsafeMutableBufferPointer { out in
            compression_decode_buffer(out.baseAddress!, out.count, base, source.count, nil, COMPRESSION_ZLIB)
        }
        guard written == expectedSize else {
            throw ZipError.corrupt("inflated \(written) bytes, expected \(expectedSize)")
        }
        output.removeLast()
        return output
    }

    /// 压缩。压不小（或者压缩失败）返回 nil，调用方改用不压缩的 stored。
    static func deflate(_ source: [UInt8]) -> [UInt8]? {
        guard !source.isEmpty else { return nil }
        var output = [UInt8](repeating: 0, count: source.count)
        let written = source.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { out in
                compression_encode_buffer(out.baseAddress!, out.count, input.baseAddress!, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        // 0 表示输出缓冲区装不下：压出来不比原文小，不值得压。
        guard written > 0, written < source.count else { return nil }
        return Array(output.prefix(written))
    }
}
