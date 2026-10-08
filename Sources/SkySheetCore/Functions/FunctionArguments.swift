import Foundation

/// 函数拿到的参数。取参和类型转换统一在这里做一次，不在每个函数里各写一遍（设计 5.2 节）。
/// 转不了的抛出 `CellError`，就是格子里要显示的那个错误。
struct FunctionArguments {
    let values: [EvalValue]
    let evaluator: Evaluator

    var context: any EvaluationContext { evaluator.context }
    var count: Int { values.count }

    /// 没写，或者写了但空着（PMT(r, n, pv, , 1) 的第 4 个）。
    func isOmitted(_ index: Int) -> Bool {
        guard index < values.count else { return true }
        if case .missing = values[index] { return true }
        return false
    }

    /// 当一个值用：区域按隐式交集取一格。
    func scalar(_ index: Int) -> CellValue {
        index < values.count ? evaluator.scalar(values[index]) : .empty
    }

    func number(_ index: Int) throws(CellError) -> Decimal {
        try Coercion.number(scalar(index))
    }

    func number(_ index: Int, default fallback: Decimal) throws(CellError) -> Decimal {
        isOmitted(index) ? fallback : try number(index)
    }

    func double(_ index: Int) throws(CellError) -> Double {
        DecimalMath.double(try number(index))
    }

    func double(_ index: Int, default fallback: Double) throws(CellError) -> Double {
        isOmitted(index) ? fallback : try double(index)
    }

    /// 整数参数：Excel 一律向零截断（ROUND(x, 1.9) 按 1 位算）。
    func integer(_ index: Int) throws(CellError) -> Int {
        guard let value = DecimalMath.int(try number(index)) else { throw CellError.num }
        return value
    }

    func integer(_ index: Int, default fallback: Int) throws(CellError) -> Int {
        isOmitted(index) ? fallback : try integer(index)
    }

    func text(_ index: Int) throws(CellError) -> String {
        try Coercion.text(scalar(index))
    }

    func bool(_ index: Int, default fallback: Bool) throws(CellError) -> Bool {
        isOmitted(index) ? fallback : try Coercion.bool(scalar(index))
    }

    func area(_ index: Int) -> Area? {
        guard index < values.count, case .area(let area) = values[index] else { return nil }
        return area
    }

    /// 参数当二维表取出来：区域，或者单个值（1×1）。
    /// 整列、整行引用（A:A）裁掉「用到的范围」以外的尾部，左上角不动，位置照样对得上。
    func grid(_ index: Int) throws(CellError) -> Grid {
        guard let area = area(index) else { return Grid(single: try errorChecked(scalar(index))) }
        var range = area.range
        if let used = context.usedRange(sheet: area.sheet) {
            let bottom = min(range.end.row, max(used.end.row, range.start.row))
            let right = min(range.end.column, max(used.end.column, range.start.column))
            range = CellRange(range.start, CellAddress(row: bottom, column: right))
        } else {
            range = CellRange(range.start)
        }
        return try Grid(area: Area(sheet: area.sheet, range: range), rows: range.rowCount, columns: range.columnCount,
                        context: context)
    }

    /// 和 `shape` 一样大小、从参数区域的左上角开始取。SUMIF 的求和区域、XLOOKUP 的结果区域按这个对齐位置。
    func grid(_ index: Int, shapedLike shape: Grid) throws(CellError) -> Grid {
        guard let area = area(index) else { return Grid(single: try errorChecked(scalar(index))) }
        let end = CellAddress(row: area.range.start.row + shape.rows - 1, column: area.range.start.column + shape.columns - 1)
        guard end.row < CellAddress.maxRows, end.column < CellAddress.maxColumns else { throw CellError.ref }
        return try Grid(area: Area(sheet: area.sheet, range: CellRange(area.range.start, end)),
                        rows: shape.rows, columns: shape.columns, context: context)
    }

    private func errorChecked(_ value: CellValue) throws(CellError) -> CellValue {
        if case .error(let error) = value { throw error }
        return value
    }
}

/// 一块二维的值，行优先存放。
struct Grid {
    let rows: Int
    let columns: Int
    private(set) var values: [CellValue]

    init(single value: CellValue) {
        rows = 1
        columns = 1
        values = [value]
    }

    init(area: Area, rows: Int, columns: Int, context: any EvaluationContext) throws(CellError) {
        // 一百万格以上的区域多半是写错了（比如 A:Z 整列又没有被裁掉），不要把内存撑爆。
        guard rows * columns <= 1_000_000 else { throw CellError.num }
        self.rows = rows
        self.columns = columns
        var values = [CellValue](repeating: .empty, count: rows * columns)
        for (address, value) in context.entries(in: area) {
            values[(address.row - area.range.start.row) * columns + (address.column - area.range.start.column)] = value
        }
        self.values = values
    }

    subscript(row: Int, column: Int) -> CellValue {
        values[row * columns + column]
    }

    /// 一行或者一列。
    var isVector: Bool { rows == 1 || columns == 1 }
}
