import Foundation

/// 行还是列。
public enum SheetAxis: Hashable, Sendable {
    case rows, columns

    /// 这个方向上最多几行（列）：Excel 的上限。
    public var limit: Int { self == .rows ? CellAddress.maxRows : CellAddress.maxColumns }

    /// 格子在这个方向上的序号（行号或列号）。
    public func index(of address: CellAddress) -> Int { self == .rows ? address.row : address.column }

    /// 把格子在这个方向上的序号换成 `index`，另一个方向不动。
    public func moving(_ address: CellAddress, to index: Int) -> CellAddress {
        self == .rows ? CellAddress(row: index, column: address.column) : CellAddress(row: address.row, column: index)
    }

    /// 区域在这个方向上占的那一段。
    public func span(of range: CellRange) -> ClosedRange<Int> {
        self == .rows ? range.start.row...range.end.row : range.start.column...range.end.column
    }

    /// 把区域在这个方向上的那一段换成 `span`，另一个方向不动。
    public func replacing(_ span: ClosedRange<Int>, in range: CellRange) -> CellRange {
        CellRange(moving(range.start, to: span.lowerBound), moving(range.end, to: span.upperBound))
    }
}

/// 插入或删除一段行（列）以后，原来的第 n 行（列）到了哪里（设计第 11 条，2026-10-14 起插删行列）。
/// 插删时格子、行高列宽、合并单元格、冻结窗格、数组公式的范围、公式里的引用都按它挪，只有这一份。
///
/// 规矩和 Excel 一样：插在一段中间，这一段撑大；插在一段的第一行上，整段往下挪；删掉一段的一部分，这一段缩小；
/// 整段都删掉，指向它的引用变成 #REF!。带不带 $ 都一样挪（$ 只管复制公式时平移不平移）。
public struct LineShift: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case insert, delete
    }

    public let axis: SheetAxis
    public let kind: Kind
    /// 插入：新行从这一行开始（原来的这一行和下面的往下挪）；删除：删掉的第一行。从 0 开始。
    public let start: Int
    /// 插几行、删几行（至少 1）。
    public let count: Int

    public static func insert(_ count: Int, at start: Int, _ axis: SheetAxis) -> LineShift {
        LineShift(axis: axis, kind: .insert, start: start, count: max(count, 1))
    }

    public static func delete(_ lines: ClosedRange<Int>, _ axis: SheetAxis) -> LineShift {
        LineShift(axis: axis, kind: .delete, start: lines.lowerBound, count: lines.count)
    }

    /// 插入：新插进来的那几行；删除：删掉的那几行（都是挪之前的序号）。
    public var lines: ClosedRange<Int> { start...(start + count - 1) }

    /// 原来的第 `index` 行现在是第几行。删掉了、或者被挤出表外了是 nil。
    public func map(_ index: Int) -> Int? {
        switch kind {
        case .insert:
            guard index >= start else { return index }
            return index + count < axis.limit ? index + count : nil
        case .delete:
            if index < start { return index }
            return index < start + count ? nil : index - count
        }
    }

    /// 一段（比如 A3:B9 的第 3…9 行）挪完以后是哪一段。整段都删掉了是 nil；挤到表外的部分截掉。
    public func map(_ span: ClosedRange<Int>) -> ClosedRange<Int>? {
        switch kind {
        case .insert:
            let lower = span.lowerBound >= start ? span.lowerBound + count : span.lowerBound
            let upper = span.upperBound >= start ? span.upperBound + count : span.upperBound
            guard lower < axis.limit else { return nil }
            return lower...min(upper, axis.limit - 1)
        case .delete:
            let last = start + count - 1
            // 起点落在删掉的那段里：从删掉那段后面的第一行算起（它现在的序号就是 start）；终点落在里面：到删掉那段前面为止。
            let lower = span.lowerBound < start ? span.lowerBound : (span.lowerBound > last ? span.lowerBound - count : start)
            let upper = span.upperBound < start ? span.upperBound : (span.upperBound > last ? span.upperBound - count : start - 1)
            return lower <= upper ? lower...upper : nil
        }
    }

    /// 一块区域挪完以后的样子（只动这个方向）。整块都删掉了是 nil。
    public func map(_ range: CellRange) -> CellRange? {
        map(axis.span(of: range)).map { axis.replacing($0, in: range) }
    }
}
