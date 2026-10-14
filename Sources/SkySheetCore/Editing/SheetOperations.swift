import Foundation

/// sheet 级的操作：新建、复制、挪位置、往下填充（设计 9.2 节的 add_sheet、edit_sheet、write_cells 用它们）。
/// 改样式在 CellStyling，行高列宽和冻结窗格在 RowColumnFormats，插删行列在 StructureEditing。
/// 和 WorkbookEditing 一样都是值类型上的修改，调用方改完自己整本重算、登记撤销。
extension Workbook {
    /// 新建一张空 sheet，放在 `position`（默认最后），返回它的下标。
    @discardableResult
    public mutating func addSheet(named name: String, at position: Int? = nil,
                                  role: SheetRole = .original) throws(SheetEditError) -> Int {
        if let problem = SheetName.problem(with: name, among: sheets.map(\.name)) {
            throw SheetEditError.invalidName(problem)
        }
        let index = min(max(position ?? sheets.count, 0), sheets.count)
        insertSheet(Sheet(id: nextSheetID, name: name, role: role), at: index)
        nextSheetID += 1
        return index
    }

    /// 复制一张，放在它后面。`name` 为 nil 时叫「原名 (2)」。里面的公式照抄：没写 sheet 名的引用指向复制出来的这张，
    /// 写了原 sheet 名的仍然指向原来那张（Excel 也这样）。
    @discardableResult
    public mutating func copySheet(_ index: Int, named name: String? = nil) throws(SheetEditError) -> Int {
        var copy = sheets[index]
        copy.name = name ?? SheetName.copyName(of: copy.name, among: sheets.map(\.name))
        if let problem = SheetName.problem(with: copy.name, among: sheets.map(\.name)) {
            throw SheetEditError.invalidName(problem)
        }
        copy.id = nextSheetID
        copy.visibility = .visible
        insertSheet(copy, at: index + 1)
        nextSheetID += 1
        return index + 1
    }

    /// 挪一张 sheet 的位置（`to` 是挪完以后的下标）。只在某张 sheet 里有效的定义名称跟着它走。
    public mutating func moveSheet(from: Int, to: Int) {
        let target = min(max(to, 0), sheets.count - 1)
        guard sheets.indices.contains(from), from != target else { return }
        var order = Array(sheets.indices)
        order.insert(order.remove(at: from), at: target)
        sheets = order.map { sheets[$0] }
        let newIndex = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        for position in definedNames.indices {
            definedNames[position].sheetIndex = definedNames[position].sheetIndex.flatMap { newIndex[$0] }
        }
    }

    /// 插进一张 sheet：只在后面那些 sheet 里有效的名称，下标跟着往后挪一位。
    mutating func insertSheet(_ sheet: Sheet, at index: Int) {
        sheets.insert(sheet, at: index)
        for position in definedNames.indices {
            if let scope = definedNames[position].sheetIndex, scope >= index {
                definedNames[position].sheetIndex = scope + 1
            }
        }
    }

    // MARK: - 往下填充

    /// 把 `row` 这一行的 `columns` 几列往下填到 `lastRow`（和 Excel 拖填充柄一样）：公式的引用按行平移，值和样式照抄，
    /// 空格子也照抄成空。
    public mutating func fillDown(row: Int, columns: ClosedRange<Int>, through lastRow: Int, sheet index: Int) {
        guard lastRow > row else { return }
        for column in columns {
            let source = sheets[index].cells[row, column]
            for target in (row + 1)...lastRow {
                guard var cell = source else {
                    sheets[index].cells[target, column] = nil
                    continue
                }
                if var formula = cell.formula {
                    formula.source = ReferenceShift.shift(formula.source, rows: target - row, columns: 0)
                    formula.cachedValue = nil
                    formula.status = .pending
                    formula.arrayRange = nil
                    cell.formula = formula
                    cell.value = .empty
                }
                sheets[index].cells[target, column] = cell
            }
        }
    }
}
