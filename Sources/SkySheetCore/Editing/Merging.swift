import Foundation

/// 合并、拆开单元格（2026-10-14 加，界面的 Format 菜单和 AI 的 format_cells 共用）。
public enum MergeError: Error, Equatable, Sendable {
    /// 和一个已有的合并单元格只交叉了一部分（Excel 也不让这样合并）。
    case overlapsMerge(CellRange)
    /// 左上角以外的这些格子有内容，合并会把它们丢掉。界面先问用户；AI 要先自己清掉。
    case wouldDiscard([CellAddress])
}

extension Workbook {
    /// 合并 `range` 会丢掉内容的格子：左上角以外有值或公式的（和 Excel 一样，合并只留左上角那一格）。
    public func cellsLostByMerging(_ range: CellRange, sheet index: Int) -> [CellAddress] {
        sheets[index].cells.entries(in: range).filter { entry in
            entry.address != range.start && (entry.value.value != .empty || entry.value.formula != nil)
        }.map(\.address)
    }

    /// 把 `range` 合并成一格。里面原来的合并单元格并进来；左上角以外有内容时，`discardingOthers` 才清掉它们，否则报错。
    /// 整块都换成左上角那一格的样式（和 Excel 一样：拆开以后每一格还是合并时的样子）。一格的区域什么都不做。
    public mutating func merge(_ range: CellRange, sheet index: Int, discardingOthers: Bool = false) throws(MergeError) {
        guard range.rowCount * range.columnCount > 1 else { return }
        for merge in sheets[index].merges where merge.intersection(range) != nil && merge.intersection(range) != merge {
            throw MergeError.overlapsMerge(merge)
        }
        let lost = cellsLostByMerging(range, sheet: index)
        if !lost.isEmpty, !discardingOthers { throw MergeError.wouldDiscard(lost) }
        let style = sheets[index].cells[range.start]?.styleIndex ?? 0
        for row in range.start.row...range.end.row {
            for column in range.start.column...range.end.column where CellAddress(row: row, column: column) != range.start {
                sheets[index].cells[row, column] = style == 0 ? nil : Cell(styleIndex: style)
            }
        }
        sheets[index].merges.removeAll { $0.intersection(range) != nil }
        sheets[index].merges.append(range)
    }

    /// 拆开和 `range` 有交集的合并单元格，返回拆了几个。内容留在左上角那一格。
    @discardableResult
    public mutating func unmerge(_ range: CellRange, sheet index: Int) -> Int {
        let before = sheets[index].merges.count
        sheets[index].merges.removeAll { $0.intersection(range) != nil }
        return before - sheets[index].merges.count
    }
}
