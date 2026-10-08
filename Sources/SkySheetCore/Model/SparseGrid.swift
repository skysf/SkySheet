import Foundation

/// 稀疏的二维存储：只存有东西的格子（行 → 列 → 值）。
/// 单元格、AI 这一轮改过的高亮……凡是「按格子记点什么」的都用它，不各写一份（设计第四节）。
public struct SparseGrid<Value: Sendable>: Sendable {
    private var rows: [Int: [Int: Value]] = [:]
    public private(set) var count = 0

    public init() {}

    public subscript(row: Int, column: Int) -> Value? {
        get { rows[row]?[column] }
        set {
            if let newValue {
                if rows[row, default: [:]].updateValue(newValue, forKey: column) == nil {
                    count += 1
                }
            } else if rows[row]?.removeValue(forKey: column) != nil {
                count -= 1
                if rows[row]?.isEmpty == true {
                    rows[row] = nil
                }
            }
        }
    }

    public subscript(address: CellAddress) -> Value? {
        get { self[address.row, address.column] }
        set { self[address.row, address.column] = newValue }
    }

    public var isEmpty: Bool { count == 0 }

    /// 有东西的行，从上到下。
    public var rowIndices: [Int] { rows.keys.sorted() }

    /// 一行里有东西的格子，从左到右。
    public func row(_ index: Int) -> [(column: Int, value: Value)] {
        (rows[index] ?? [:]).sorted { $0.key < $1.key }.map { (column: $0.key, value: $0.value) }
    }

    /// 按行优先的顺序遍历所有格子。
    public func forEach(_ body: (CellAddress, Value) throws -> Void) rethrows {
        for rowIndex in rowIndices {
            for (column, value) in row(rowIndex) {
                try body(CellAddress(row: rowIndex, column: column), value)
            }
        }
    }

    /// 区域里有东西的格子，行优先。只碰存在的行和列：整列引用（A:A，一百多万行）也不慢。
    public func entries(in range: CellRange) -> [(address: CellAddress, value: Value)] {
        let rowSpan = range.start.row...range.end.row
        let columnSpan = range.start.column...range.end.column
        let rowKeys: [Int] = rowSpan.count < rows.count
            ? rowSpan.filter { rows[$0] != nil }
            : rows.keys.filter { rowSpan.contains($0) }.sorted()
        var result: [(address: CellAddress, value: Value)] = []
        for rowIndex in rowKeys {
            guard let line = rows[rowIndex] else { continue }
            let columns: [Int] = columnSpan.count < line.count
                ? columnSpan.filter { line[$0] != nil }
                : line.keys.filter { columnSpan.contains($0) }.sorted()
            for column in columns {
                result.append((CellAddress(row: rowIndex, column: column), line[column]!))
            }
        }
        return result
    }

    /// 用到的范围：有东西的最上、最下、最左、最右围成的矩形。空的返回 nil。
    public var usedRange: CellRange? {
        guard let top = rows.keys.min(), let bottom = rows.keys.max() else { return nil }
        var left = Int.max
        var right = Int.min
        for line in rows.values {
            for column in line.keys {
                left = min(left, column)
                right = max(right, column)
            }
        }
        return CellRange(CellAddress(row: top, column: left), CellAddress(row: bottom, column: right))
    }
}

extension SparseGrid: Equatable where Value: Equatable {}
extension SparseGrid: Hashable where Value: Hashable {}
