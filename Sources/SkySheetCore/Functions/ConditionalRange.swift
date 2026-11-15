import Foundation

/// 保留引用的逻辑形状，只存有值的位置；entries 已按行序返回，无须再建字典或排序。
struct ConditionalRange {
    let rows: Int
    let columns: Int
    let entries: [(position: Int, value: CellValue)]

    var count: Int { rows * columns }
}

extension FunctionArguments {
    /// 只有 SUMIF / AVERAGEIF 的目标区域允许从左上角扩展；越过工作表的部分没有值，仍按逻辑列宽对齐。
    func conditionalRange(_ index: Int, shapedLike shape: ConditionalRange? = nil,
                          expand: Bool = false) throws(CellError) -> ConditionalRange {
        guard let area = area(index) else {
            if let shape, shape.rows != 1 || shape.columns != 1 { throw CellError.value }
            let value = scalar(index)
            if case .error(let error) = value { throw error }
            return ConditionalRange(rows: 1, columns: 1, entries: value == .empty ? [] : [(0, value)])
        }
        var range = area.range
        let rows = expand ? shape?.rows ?? range.rowCount : range.rowCount
        let columns = expand ? shape?.columns ?? range.columnCount : range.columnCount
        if let shape {
            if expand {
                let end = CellAddress(row: min(CellAddress.maxRows - 1, range.start.row + rows - 1),
                                      column: min(CellAddress.maxColumns - 1, range.start.column + columns - 1))
                range = CellRange(range.start, end)
            } else {
                guard range.rowCount == shape.rows, range.columnCount == shape.columns else { throw CellError.value }
            }
        }
        let entries = context.entries(in: Area(sheet: area.sheet, range: range)).map { address, value in
            ((address.row - range.start.row) * columns + address.column - range.start.column, value)
        }
        return ConditionalRange(rows: rows, columns: columns, entries: entries)
    }
}
