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
