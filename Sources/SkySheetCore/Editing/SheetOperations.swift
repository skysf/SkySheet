import Foundation

/// sheet 级的操作：新建、复制、挪位置、往下填充、改样式、列宽、冻结窗格（设计 9.2 节的 add_sheet、edit_sheet、
/// write_cells、format_cells 用它们；以后界面上的同类功能也用这一份）。和 WorkbookEditing 一样都是值类型上的修改，
/// 调用方改完自己整本重算、登记撤销。
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

    // MARK: - 样式

    /// 一次样式修改：只改给了的几样（设计 9.2 节 format_cells）。
    public struct CellStyleChange: Sendable, Equatable {
        /// 数字格式代码（预设先换成代码再传进来）。
        public var numberFormat: String?
        public var bold: Bool?
        /// ARGB 十六进制，如 "FFC00000"。
        public var fontColor: String?
        public var fillColor: String?

        public init(numberFormat: String? = nil, bold: Bool? = nil, fontColor: String? = nil, fillColor: String? = nil) {
            self.numberFormat = numberFormat
            self.bold = bold
            self.fontColor = fontColor
            self.fillColor = fillColor
        }

        public var isEmpty: Bool { numberFormat == nil && bold == nil && fontColor == nil && fillColor == nil }
    }

    /// 给一块格子改样式，空格子也带上（和 Excel 一样）。样式表只往后加（设计 7.2 节），同样的组合复用同一个编号。
    /// 调用方先把区域限制在合理的大小（整列引用有一百多万格）。
    public mutating func restyle(_ range: CellRange, sheet index: Int, _ change: CellStyleChange) {
        guard !change.isEmpty else { return }
        var memo: [Int: Int] = [:]
        for row in range.start.row...range.end.row {
            for column in range.start.column...range.end.column {
                var cell = sheets[index].cells[row, column] ?? Cell()
                let style = memo[cell.styleIndex] ?? restyled(cell.styleIndex, change)
                memo[cell.styleIndex] = style
                cell.styleIndex = style
                sheets[index].cells[row, column] = cell == Cell() ? nil : cell
            }
        }
    }

    /// `base` 这个样式按 `change` 改完以后的编号：已经有一模一样的就用它，没有才往后加。
    mutating func restyled(_ base: Int, _ change: CellStyleChange) -> Int {
        var format = styles.cellFormats.indices.contains(base) ? styles.cellFormats[base] : CellFormat()
        if let code = change.numberFormat { format.numberFormatID = numberFormatID(forCode: code) }
        if change.bold != nil || change.fontColor != nil {
            var font = styles.fonts.indices.contains(format.fontID) ? styles.fonts[format.fontID] : FontStyle()
            if let bold = change.bold { font.bold = bold }
            if let color = change.fontColor { font.color = StyleColor(.rgb(color)) }
            format.fontID = Self.index(of: font, in: &styles.fonts)
        }
        if let color = change.fillColor {
            let fill = FillStyle(pattern: "solid", foreground: StyleColor(.rgb(color)), background: StyleColor(.indexed(64)))
            format.fillID = Self.index(of: fill, in: &styles.fills)
        }
        return Self.index(of: format, in: &styles.cellFormats)
    }

    /// 格式代码 → 编号：几个各地都一样的内置格式用内置编号，别的用自定义编号（已有的复用，没有的从 164 往后加）。
    mutating func numberFormatID(forCode code: String) -> Int {
        if let builtin = BuiltinFormats.id(forCode: code) { return builtin }
        if let existing = styles.customNumberFormats.first(where: { $0.value == code })?.key { return existing }
        // 自定义格式从 164 开始编（0–163 留给内置格式）。
        let id = max(163, styles.customNumberFormats.keys.max() ?? 163) + 1
        styles.customNumberFormats[id] = code
        return id
    }

    private static func index<T: Equatable>(of item: T, in list: inout [T]) -> Int {
        if let existing = list.firstIndex(of: item) { return existing }
        list.append(item)
        return list.count - 1
    }

    // MARK: - 列宽、冻结窗格

    /// 设几列的列宽（Excel 的字符数）。这几列原来的隐藏、样式留着；挨着的、设得一样的列并成一段。
    public mutating func setColumnWidth(_ width: Double, columns: ClosedRange<Int>, sheet index: Int) {
        let existing = sheets[index].columns
        var result: [ColumnFormat] = []
        for format in existing {
            if format.first < columns.lowerBound {
                var before = format
                before.last = min(format.last, columns.lowerBound - 1)
                result.append(before)
            }
            if format.last > columns.upperBound {
                var after = format
                after.first = max(format.first, columns.upperBound + 1)
                result.append(after)
            }
        }
        for column in columns {
            let old = existing.first { ($0.first...$0.last).contains(column) }
            result.append(ColumnFormat(first: column, last: column, width: width, hidden: old?.hidden ?? false,
                                       styleIndex: old?.styleIndex))
        }
        result.sort { $0.first < $1.first }
        var merged: [ColumnFormat] = []
        for format in result {
            if var last = merged.last, last.last + 1 == format.first, last.width == format.width,
               last.hidden == format.hidden, last.styleIndex == format.styleIndex {
                last.last = format.last
                merged[merged.count - 1] = last
            } else {
                merged.append(format)
            }
        }
        sheets[index].columns = merged
    }

    /// 冻结上面 `rows` 行、左边 `columns` 列；都是 0 就是不冻结。
    public mutating func freeze(rows: Int, columns: Int, sheet index: Int) {
        sheets[index].frozen = rows > 0 || columns > 0 ? FrozenPanes(rows: rows, columns: columns) : nil
    }
}
