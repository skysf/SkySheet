import Foundation

/// 要展开的格子比上限多（导出 csv、SQL 点名的区域）。
public struct TooManyCells: Error, Equatable, Sendable {
    /// 要展开的格子数（几块加起来）。
    public var cells: Int
    public var limit: Int

    public init(cells: Int, limit: Int) {
        self.cells = cells
        self.limit = limit
    }
}

/// 把 AI 给的区域整块展开成格子（一格一格地写成 csv、装进 SQL 的表）之前，先按面积查（设计 9.7 节）。
/// 区域是 AI 说了算的：A1:XFD1048576 有 172 亿格，展开之前不拦，一个调用就能把内存吃光（2026-11-16 排查第 9、10 条）。
public enum ExpansionLimit {
    /// 导出、SQL 点名的区域，一次最多展开这么多格。设计里测过的大表（8.2 节，10 万行 × 20 列）是 200 万格，
    /// 留到 5 倍：SkySheet 打得开、算得动的表照样能整张导出、整块查；整列整行（每列一百多万格）也能点名九列。
    public static let cells = 10_000_000

    /// 这几块加起来不超过 `limit` 格就过，否则抛错。
    public static func check(_ ranges: [CellRange], limit: Int = cells) throws(TooManyCells) {
        var total = 0
        for range in ranges {
            // 一块最多 172 亿格，要五亿多块加起来才会溢出；还是按饱和加，一个参数不该有让 App 崩溃的可能。
            let (sum, overflow) = total.addingReportingOverflow(range.rowCount * range.columnCount)
            total = overflow ? .max : sum
        }
        guard total <= limit else { throw TooManyCells(cells: total, limit: limit) }
    }
}
