import Foundation

/// zip 里的一个条目（一个文件或一个目录），信息全部来自中央目录。
public struct ZipEntry: Equatable, Sendable {
    public enum Method: Equatable, Sendable {
        case stored
        case deflated
        /// 读的时候不认识的压缩方式，列目录时照样列出来，取内容时才报错。
        case other(Int)
    }

    public let name: String
    public let method: Method
    public let crc32: UInt32
    public let compressedSize: Int
    public let uncompressedSize: Int
    public let modified: DOSDateTime
    /// 本地文件头在整个 zip 里的位置。
    let localHeaderOffset: Int

    public var isDirectory: Bool { name.hasSuffix("/") }
}

/// zip 用的 MS-DOS 日期时间（精确到 2 秒）。原样保留文件里的值，保存时照抄，不换算。
public struct DOSDateTime: Equatable, Hashable, Sendable {
    public var time: UInt16
    public var date: UInt16

    public init(time: UInt16, date: UInt16) {
        self.time = time
        self.date = date
    }

    /// 1980-01-01 00:00，DOS 日期能表示的最早时刻。
    public static let earliest = DOSDateTime(time: 0, date: 1 << 5 | 1)

    /// 用本地时间换算（zip 里存的就是本地时间，没有时区）。
    public init(_ value: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: value)
        let year = min(max((c.year ?? 1980) - 1980, 0), 127)
        date = UInt16(year << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
    }
}
