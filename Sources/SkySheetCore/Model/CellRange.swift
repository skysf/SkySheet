import Foundation

/// 一块矩形区域，两角都包含在内。构造时自动摆正：`start` 是左上角，`end` 是右下角。
public struct CellRange: Hashable, Sendable, CustomStringConvertible {
    public let start: CellAddress
    public let end: CellAddress

    public init(_ first: CellAddress, _ second: CellAddress) {
        start = CellAddress(row: min(first.row, second.row), column: min(first.column, second.column))
        end = CellAddress(row: max(first.row, second.row), column: max(first.column, second.column))
    }

    public init(_ single: CellAddress) {
        self.init(single, single)
    }

    /// "A1:B3" 或 "A1"（$ 忽略）。
    public init?(a1 text: some StringProtocol) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            guard let only = CellAddress(a1: parts[0]) else { return nil }
            self.init(only)
        case 2:
            guard let first = CellAddress(a1: parts[0]), let second = CellAddress(a1: parts[1]) else { return nil }
            self.init(first, second)
        default:
            return nil
        }
    }

    public var a1: String { start == end ? start.a1 : "\(start.a1):\(end.a1)" }
    public var description: String { a1 }

    public var rowCount: Int { end.row - start.row + 1 }
    public var columnCount: Int { end.column - start.column + 1 }

    public func contains(_ address: CellAddress) -> Bool {
        (start.row...end.row).contains(address.row) && (start.column...end.column).contains(address.column)
    }

    public func intersection(_ other: CellRange) -> CellRange? {
        let top = max(start.row, other.start.row)
        let bottom = min(end.row, other.end.row)
        let left = max(start.column, other.start.column)
        let right = min(end.column, other.end.column)
        guard top <= bottom, left <= right else { return nil }
        return CellRange(CellAddress(row: top, column: left), CellAddress(row: bottom, column: right))
    }
}

/// 整列（C:E）、整行（3:5）的写法（2026-10-14 加：点列标行号选整列整行，AI 的 edit_rows_columns 也按列、按行说）。
extension CellRange {
    /// "C:E"、"C"、"$C:$E" → 第 2…4 列（从 0 开始，倒着写的摆正）。不是列的写法返回 nil。
    public static func columnSpan(a1 text: some StringProtocol) -> ClosedRange<Int>? {
        span(text) { CellAddress.columnIndex($0) }
    }

    /// "3:5"、"3"、"$3:$5" → 第 2…4 行（从 0 开始）。
    public static func rowSpan(a1 text: some StringProtocol) -> ClosedRange<Int>? {
        span(text) { Int($0).flatMap { (1...CellAddress.maxRows).contains($0) ? $0 - 1 : nil } }
    }

    /// 几整列：C:E 就是 C1:E1048576。
    public static func columns(_ span: ClosedRange<Int>) -> CellRange {
        CellRange(CellAddress(row: 0, column: span.lowerBound), CellAddress(row: CellAddress.maxRows - 1, column: span.upperBound))
    }

    /// 几整行：3:5 就是 A3:XFD5。
    public static func rows(_ span: ClosedRange<Int>) -> CellRange {
        CellRange(CellAddress(row: span.lowerBound, column: 0), CellAddress(row: span.upperBound, column: CellAddress.maxColumns - 1))
    }

    /// 一块格子（B2、A1:C3）、整列（C:E、C）或整行（3:5、3）都认（$ 忽略）。AI 的参数、截图模式的 --select 用它。
    public static func parse(_ text: some StringProtocol) -> CellRange? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return CellRange(a1: trimmed) ?? columnSpan(a1: trimmed).map(columns) ?? rowSpan(a1: trimmed).map(rows)
    }

    /// 铺满所有行（整列）。
    public var coversAllRows: Bool { start.row == 0 && end.row == CellAddress.maxRows - 1 }
    /// 铺满所有列（整行）。
    public var coversAllColumns: Bool { start.column == 0 && end.column == CellAddress.maxColumns - 1 }

    /// 给人和 AI 看的写法：整列写成 C:E，整行写成 3:5，别的同 `a1`。
    public var label: String {
        if coversAllRows, !coversAllColumns {
            return CellAddress.columnName(start.column) + ":" + CellAddress.columnName(end.column)
        }
        if coversAllColumns, !coversAllRows { return "\(start.row + 1):\(end.row + 1)" }
        return a1
    }

    private static func span(_ text: some StringProtocol, _ index: (String) -> Int?) -> ClosedRange<Int>? {
        let parts = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
            .split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let first = index(String(parts[0])),
              let last = index(String(parts[parts.count - 1])) else { return nil }
        return min(first, last)...max(first, last)
    }
}
