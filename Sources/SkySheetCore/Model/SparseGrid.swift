import Foundation

/// 稀疏的二维存储：只存有东西的格子（行 → 列 → 值）。
/// 单元格、AI 这一轮改过的高亮……凡是「按格子记点什么」的都用它，不各写一份（设计第四节）。
public struct SparseGrid<Value: Sendable>: Sendable {
    /// `@usableFromInline`：几个热循环（`forEachUnordered(in:)`）标了 @inlinable，要在调用的模块里按具体类型展开，
    /// 不然跨模块调泛型函数每格都要查一遍类型信息（2026-11-14 实测全选时占了合计的大半）。
    @usableFromInline var rows: [Int: [Int: Value]] = [:]
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

    /// 一行里落在 `columns` 里的格子，从左到右；和 `row(_:)` 再按列筛一遍的结果一样，但不把整行连值一起排序。
    /// 画表格每一帧对每一行都要这么取：整行（值是带文字的 Cell）排一次序曾经占了一帧的四成（2026-11-14 实测）。
    /// 看的列比这一行的格子少，就按列一格一格查；否则只把这一段的列号排序。
    /// 返回数组而不是收一个闭包：主线程上的代码传进来的闭包，Swift 6 每调一次都要核对一遍是不是在主线程上，画的时候很贵。
    public func entries(inRow index: Int, columns: Range<Int>) -> [(column: Int, value: Value)] {
        guard let line = rows[index], !columns.isEmpty else { return [] }
        var result: [(column: Int, value: Value)] = []
        if columns.count <= line.count {
            for column in columns {
                if let value = line[column] { result.append((column, value)) }
            }
        } else {
            var keys: [Int] = []
            keys.reserveCapacity(line.count)
            for column in line.keys where columns.contains(column) { keys.append(column) }
            keys.sort()
            result.reserveCapacity(keys.count)
            for column in keys { result.append((column, line[column]!)) }
        }
        return result
    }

    /// 所有格子，不排序（顺序不定）。只要挨个看一遍、和顺序无关时用它：十万行的表按行列排好序再看，光排序就要几百毫秒
    /// （重算前找公式，2026-11-14）。
    public func forEachUnordered(_ body: (CellAddress, Value) throws -> Void) rethrows {
        for (rowIndex, line) in rows {
            for (column, value) in line {
                try body(CellAddress(row: rowIndex, column: column), value)
            }
        }
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
        var result: [(address: CellAddress, value: Value)] = []
        forEach(in: range) { address, value in result.append((address, value)) }
        return result
    }

    /// 区域里有东西的格子，顺序不定（和 `forEach(in:)` 是同一批）。区域比表小就按区域的行列查，否则直接走存储、不排序：
    /// 全选十万行的表求合计、计数时，排序和跨模块的泛型开销曾经占了一大半（2026-11-14）。
    @inlinable
    public func forEachUnordered(in range: CellRange, _ body: (CellAddress, Value) throws -> Void) rethrows {
        let rowSpan = range.start.row...range.end.row
        let columnSpan = range.start.column...range.end.column
        if rowSpan.count < rows.count {
            for row in rowSpan {
                if let line = rows[row] { try Self.visit(line, row: row, columns: columnSpan, body) }
            }
        } else {
            for (row, line) in rows where rowSpan.contains(row) {
                try Self.visit(line, row: row, columns: columnSpan, body)
            }
        }
    }

    @inlinable
    static func visit(_ line: [Int: Value], row: Int, columns: ClosedRange<Int>,
                      _ body: (CellAddress, Value) throws -> Void) rethrows {
        if columns.count < line.count {
            for column in columns {
                if let value = line[column] { try body(CellAddress(row: row, column: column), value) }
            }
        } else {
            for (column, value) in line where columns.contains(column) {
                try body(CellAddress(row: row, column: column), value)
            }
        }
    }

    /// 和 `entries(in:)` 一样的顺序挨个交给 `body`，不先攒成数组：全选十万行的表时，攒数组本身就要几百毫秒
    /// （2026-11-14，状态栏的合计）。注意：主线程上的代码传闭包进来，Swift 6 每调一次都要核对线程，热循环里别这么用。
    public func forEach(in range: CellRange, _ body: (CellAddress, Value) throws -> Void) rethrows {
        let rowSpan = range.start.row...range.end.row
        let columnSpan = range.start.column...range.end.column
        let rowKeys: [Int] = rowSpan.count < rows.count
            ? rowSpan.filter { rows[$0] != nil }
            : rows.keys.filter { rowSpan.contains($0) }.sorted()
        for rowIndex in rowKeys {
            guard let line = rows[rowIndex] else { continue }
            let columns: [Int] = columnSpan.count < line.count
                ? columnSpan.filter { line[$0] != nil }
                : line.keys.filter { columnSpan.contains($0) }.sorted()
            for column in columns {
                try body(CellAddress(row: rowIndex, column: column), line[column]!)
            }
        }
    }

    /// 和 `other`（同一张表的上一版）比，内容不一样的行（只在一边有的也算），顺序不定。
    /// 没改过的行两边是同一份存储，比的时候当场有结果：十万行的表整张比一遍也只是每行查一次（2026-11-14，编辑以后
    /// 只看改过的行，不再把两百万个格子从头走一遍）。
    @inlinable
    public func rowsDiffering(from other: SparseGrid) -> [Int] where Value: Equatable {
        rowsDiffering(from: other, limit: .max)!
    }

    /// 同上；不一样的行超过 `limit` 就不再比下去，返回 nil（调用方从头算更省：比一行内容不同的行要逐格比）。
    /// @inlinable：在 App 里按 Cell 展开，跨模块调泛型版本每一行都要查类型信息，慢十倍（2026-11-14 实测）。
    @inlinable
    public func rowsDiffering(from other: SparseGrid, limit: Int) -> [Int]? where Value: Equatable {
        var changed: [Int] = []
        for (row, line) in rows where other.rows[row] != line {
            changed.append(row)
            if changed.count > limit { return nil }
        }
        for row in other.rows.keys where rows[row] == nil {
            changed.append(row)
            if changed.count > limit { return nil }
        }
        return changed
    }

    /// 和另一版比，存储不是同一份的行（2026-11-15）：两版共用的行（值类型写时复制，改哪一行只复制哪一行）一定一模一样，
    /// 其余的都算「可能改过」，不看内容。和 `rowsDiffering` 的区别：那个按 == 比内容，可 == 对字符串按规范等价算，
    /// é 和 e + U+0301 算相等——公式原文只换了写法时它看不出来（重新载入文件时就会这样），重算计划就会接着用旧的
    /// （RecalcCache，自检 exactTextChecks）。改一格时只有那一行不共用，和 `rowsDiffering` 一样快。
    /// 两版都得活着（调用方拿着）：活着的两份存储地址不会重，「字节一样」才说明是同一份。
    func rowsNotShared(with other: SparseGrid) -> [Int] {
        guard !Self.sameStorage(rows, other.rows) else { return [] }
        var changed: [Int] = []
        for (row, line) in rows {
            if let old = other.rows[row], Self.sameStorage(old, line) { continue }
            changed.append(row)
        }
        for row in other.rows.keys where rows[row] == nil { changed.append(row) }
        return changed
    }

    /// 两个字典是不是同一份存储：一个字典就是一个指向存储的引用，按字节比它本身。字节一样就是同一份、内容一定一样；
    /// 不一样也可能内容一样（说不准，调用方当它「可能改过」）。
    static func sameStorage<Key, Element>(_ a: [Key: Element], _ b: [Key: Element]) -> Bool {
        withUnsafeBytes(of: a) { first in withUnsafeBytes(of: b) { second in first.elementsEqual(second) } }
    }

    /// 一行里的格子，顺序不定。
    public func forEach(inRowUnordered row: Int, _ body: (Int, Value) throws -> Void) rethrows {
        guard let line = rows[row] else { return }
        for (column, value) in line { try body(column, value) }
    }

    /// 已知上一版 `other` 用到的范围是 `previous`、两版只有 `changedRows` 这几行不一样，算这一版用到的范围：
    /// 改过的行原来都不在边上（不在最上最下那一行、没有格子在最左最右那一列）时，只把改过的行并进去；否则从头数。
    /// 结果和 `usedRange` 一样。
    @inlinable
    public func usedRange(previous: CellRange?, of other: SparseGrid, changedRows: [Int]) -> CellRange? {
        guard let previous else { return usedRange }
        var top = previous.start.row, bottom = previous.end.row
        var left = previous.start.column, right = previous.end.column
        for row in changedRows {
            if row == top || row == bottom { return usedRange }
            if let old = other.rows[row], old.keys.contains(where: { $0 == left || $0 == right }) { return usedRange }
            guard let line = rows[row], !line.isEmpty else { continue }
            top = min(top, row)
            bottom = max(bottom, row)
            for column in line.keys {
                left = min(left, column)
                right = max(right, column)
            }
        }
        return CellRange(CellAddress(row: top, column: left), CellAddress(row: bottom, column: right))
    }

    /// 用到的范围：有东西的最上、最下、最左、最右围成的矩形。空的返回 nil。
    @inlinable
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

extension SparseGrid: Equatable where Value: Equatable {
    /// 和合成的一样（比格子，再比个数），写出来是为了标 @inlinable：App 里比两版表格（重建画布时）按 Cell 展开，
    /// 存储是同一份时当场有结果。
    @inlinable
    public static func == (lhs: SparseGrid, rhs: SparseGrid) -> Bool {
        lhs.rows == rhs.rows && lhs.count == rhs.count
    }
}
extension SparseGrid: Hashable where Value: Hashable {}
