import Foundation

/// 条件统计保留整个引用的形状，但只存有值的位置：整列数空白不能真的展开一百万格。
struct ConditionalRange {
    let rows: Int
    let columns: Int
    let values: [Int: CellValue]

    var count: Int { rows * columns }
}

extension FunctionArguments {
    /// 只有 SUMIF / AVERAGEIF 的目标区域允许从左上角扩展；IFS 和 XLOOKUP 的区域必须等形。
    func conditionalRange(_ index: Int, shapedLike shape: ConditionalRange? = nil,
                          expand: Bool = false) throws(CellError) -> ConditionalRange {
        guard let area = area(index) else {
            if let shape, shape.rows != 1 || shape.columns != 1 { throw CellError.value }
            let value = scalar(index)
            if case .error(let error) = value { throw error }
            return ConditionalRange(rows: 1, columns: 1, values: value == .empty ? [:] : [0: value])
        }
        var range = area.range
        if let shape {
            if expand {
                let end = CellAddress(row: range.start.row + shape.rows - 1, column: range.start.column + shape.columns - 1)
                guard end.row < CellAddress.maxRows, end.column < CellAddress.maxColumns else { throw CellError.ref }
                range = CellRange(range.start, end)
            } else {
                guard range.rowCount == shape.rows, range.columnCount == shape.columns else { throw CellError.value }
            }
        }
        var values: [Int: CellValue] = [:]
        for (address, value) in context.entries(in: Area(sheet: area.sheet, range: range)) {
            values[(address.row - range.start.row) * range.columnCount + address.column - range.start.column] = value
        }
        return ConditionalRange(rows: range.rowCount, columns: range.columnCount, values: values)
    }
}
