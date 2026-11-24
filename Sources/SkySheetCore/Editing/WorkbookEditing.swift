import Foundation

/// 编辑工作簿（设计第 16 条）。都是值类型上的修改：调用方改完自己整本重算，撤销就是换回改之前的那一份。
public enum SheetEditError: Error, Equatable, Sendable {
    case invalidName(SheetName.Problem)
    /// 不能删掉最后一张看得见的 sheet（Excel 也不让）。
    case lastVisibleSheet
}

extension Workbook {
    /// 在一格里输入。合并单元格只有左上角那一格存东西，填到合并块里别的格子等于填左上角。
    public mutating func enter(_ input: CellInput, at address: CellAddress, sheet index: Int) {
        let target = sheets[index].merges.first { $0.contains(address) }?.start ?? address
        var cell = sheets[index].cells[target] ?? Cell()
        switch input {
        case .clear:
            cell.value = .empty
            cell.formula = nil
        case .value(let value):
            cell.value = value
            cell.formula = nil
        case .formula(let source):
            cell.formula = CellFormula(source: source)
            cell.value = .empty
        case .number(let number, let format):
            cell.value = .number(number)
            cell.formula = nil
            if let format, styles.numberFormatID(forStyle: cell.styleIndex) == 0 {
                cell.styleIndex = styleIndex(basedOn: cell.styleIndex, numberFormat: format)
            }
        }
        sheets[index].cells[target] = cell == Cell() ? nil : cell
    }

    /// 清空一块的值和公式，样式留着（Delete 键）。
    public mutating func clearContents(_ range: CellRange, sheet index: Int) {
        for (address, var cell) in sheets[index].cells.entries(in: range) {
            cell.value = .empty
            cell.formula = nil
            sheets[index].cells[address] = cell.styleIndex == 0 ? nil : cell
        }
    }

    /// 粘贴一张表（制表符分隔的文字拆成的行列），从 `origin` 开始，每一格按输入的规矩解析。
    public mutating func paste(_ table: [[String]], at origin: CellAddress, sheet index: Int) {
        for (rowOffset, fields) in table.enumerated() {
            for (columnOffset, field) in fields.enumerated() {
                let address = CellAddress(row: origin.row + rowOffset, column: origin.column + columnOffset)
                guard address.row < CellAddress.maxRows, address.column < CellAddress.maxColumns else { continue }
                enter(CellInput.parse(field, dateSystem: dateSystem), at: address, sheet: index)
            }
        }
    }

    /// 改名：所有公式和定义的名称里指向旧名字的引用一起改（和 Excel 一样）。
    public mutating func renameSheet(_ index: Int, to name: String) throws(SheetEditError) {
        if let problem = SheetName.problem(with: name, among: sheets.map(\.name), ignoring: index) {
            throw SheetEditError.invalidName(problem)
        }
        let old = sheets[index].name
        sheets[index].name = name
        rewriteFormulas { FormulaRewriter.renameSheet(in: $0, from: old, to: name) }
    }

    /// 删掉一张：指向它的引用变成 #REF!，只在它里面有效的定义名称一起删，后面 sheet 的位置往前挪。
    public mutating func deleteSheet(_ index: Int) throws(SheetEditError) {
        let visible = sheets.indices.filter { sheets[$0].visibility == .visible }
        guard visible.count > 1 || sheets[index].visibility != .visible else { throw SheetEditError.lastVisibleSheet }
        let name = sheets.remove(at: index).name
        definedNames.removeAll { $0.sheetIndex == index }
        for position in definedNames.indices {
            if let scope = definedNames[position].sheetIndex, scope > index {
                definedNames[position].sheetIndex = scope - 1
            }
        }
        rewriteFormulas { FormulaRewriter.removeSheet(in: $0, named: name) }
    }

    /// 复制一张，放在它后面，名字是「原名 (2)」（SheetOperations 的 copySheet）。图片、批注这些部件不跟着复制（设计第十五节）。
    @discardableResult
    public mutating func duplicateSheet(_ index: Int) -> Int {
        // 「原名 (2)」总是合规矩的名字，不会抛错。
        (try? copySheet(index)) ?? index
    }

    /// 在 `base` 这个样式上换一个数字格式：已经有一模一样的就用它，没有才往后加（已有的编号一个不动，设计 7.2 节）。
    public mutating func styleIndex(basedOn base: Int, numberFormat: CellInput.SuggestedFormat) -> Int {
        var format = styles.cellFormats.indices.contains(base) ? styles.cellFormats[base] : CellFormat()
        switch numberFormat {
        case .builtin(let id): format.numberFormatID = id
        case .custom(let code): format.numberFormatID = numberFormatID(forCode: code)
        }
        if let existing = styles.cellFormats.firstIndex(of: format) { return existing }
        styles.cellFormats.append(format)
        return styles.cellFormats.count - 1
    }

    private mutating func rewriteFormulas(_ rewrite: (String) -> String) {
        for index in sheets.indices {
            var cells = sheets[index].cells
            sheets[index].cells.forEach { address, cell in
                guard var formula = cell.formula else { return }
                let rewritten = rewrite(formula.source)
                guard rewritten != formula.source else { return }
                formula.source = rewritten
                var changed = cell
                changed.formula = formula
                cells[address] = changed
            }
            sheets[index].cells = cells
        }
        for index in definedNames.indices {
            definedNames[index].formula = rewrite(definedNames[index].formula)
        }
    }
}

extension Workbook {
    /// 三端对同一次编辑做相同的锁定检查、重算和署名；调用方在副本上执行，拒绝时丢弃副本。
    public mutating func finishEditing(since before: Workbook, author: AIAuthorship.Mark.Author, cache: RecalcCache) -> LockedFormulaChange? {
        if let locked = lockedFormulaChange(since: before) { return locked }
        retireReplacedFormulas(since: before)
        let edited = Self.editedSheets(self, comparedTo: before)
        Recalculator.recalculate(&self, options: RecalcOptions(cache: cache))
        Self.sign(&self, sheets: edited, author: author)
        return nil
    }

    /// 内容被直接改到的 sheet（编号）。在重算之前比：没碰到的公式格子这时还是原来的值。
    private static func editedSheets(_ new: Workbook, comparedTo old: Workbook) -> Set<Int> {
        let previous = Dictionary(old.sheets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Set(new.sheets.filter { sheet in
            guard let before = previous[sheet.id] else { return false }
            return !sheet.hasSameContent(as: before) || sheet.name != before.name
        }.map(\.id))
    }

    private static func sign(_ workbook: inout Workbook, sheets: Set<Int>, author: AIAuthorship.Mark.Author) {
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        for index in workbook.sheets.indices where sheets.contains(workbook.sheets[index].id) {
            guard var authorship = workbook.sheets[index].role.authorship else { continue }
            authorship.lastChanged = AIAuthorship.Mark(author, date: now)
            workbook.sheets[index].role = .ai(authorship)
        }
    }
}
