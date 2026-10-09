import Foundation
import SkySheetCore
import SkySheetDisplay

/// 正在编辑的格子。`text` 是编辑框里现在的文字，提交时按输入的规矩（CellInput）变成值或公式。
struct CellEditing: Equatable {
    enum Origin: Equatable {
        /// 选中格子直接打字：方向键提交并移动（Excel 的「输入」模式）。
        case typing
        /// 双击、F2：方向键在文字里移动光标（Excel 的「编辑」模式）。
        case editing
        case formulaBar
    }

    var address: CellAddress
    var text: String
    var origin: Origin
}

/// 剪贴板上的一块格子（SkySheet 自己的格式，和制表符分隔的文字一起放）：每格的原始写法（公式带 "="，
/// 数字是全精度），以及它原来的位置。粘回 SkySheet 时值不按显示四舍五入，公式按位置差平移引用（和 Excel 一样）。
struct CellClip: Codable, Equatable {
    static let pasteboardType = "ai.skylu.skysheet.cells"

    var originRow: Int
    var originColumn: Int
    var rows: [[String]]
}

/// 编辑（设计第 16 条）。改工作簿只有 `apply` 一个入口：改一份副本，整本重算，换上去，再登记撤销。
/// 撤销就是换回改之前的那一份（值类型，设计第四节），连同当时看的是哪张 sheet、选中了哪里。
extension SheetSession {
    private struct Snapshot {
        let workbook: Workbook
        let sheetIndex: Int
        let selection: Selection
    }

    /// `change` 抛错时什么都不改。改完和原来一样（比如输入了原来的值）就不登记撤销。
    /// `author` 是谁改的：直接改到的 AI 的 sheet 记下「最后是谁改的」（设计 9.3 节第 5 条）；只是跟着重算变了值的不算。
    func apply(_ actionName: String, author: AIAuthorship.Mark.Author = .user,
               _ change: (inout Workbook) throws -> Void) rethrows {
        let before = Snapshot(workbook: workbook, sheetIndex: sheetIndex, selection: selection)
        var changed = workbook
        try change(&changed)
        guard changed != workbook else { return }
        let edited = Self.editedSheets(changed, comparedTo: workbook)
        Recalculator.recalculate(&changed)
        Self.sign(&changed, sheets: edited, author: author)
        replaceWorkbook(changed)
        registerUndo(restoring: before, actionName)
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

    /// 换一整本（apply、撤销、重新载入都走这里）：样式变了重建样式表，看的 sheet 还在不在。
    func replaceWorkbook(_ new: Workbook) {
        if new.styles != workbook.styles || new.themeColors != workbook.themeColors {
            styles = StyleResolver(workbook: new)
        }
        let showing = sheet.id
        workbook = new
        sheetIndex = new.sheets.firstIndex { $0.id == showing } ?? min(sheetIndex, max(new.sheets.count - 1, 0))
        if new.sheets.indices.contains(sheetIndex), new.sheets[sheetIndex].visibility != .visible {
            sheetIndex = tabIndices.first ?? 0
        }
        revision += 1
    }

    private func registerUndo(restoring snapshot: Snapshot, _ actionName: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated {
                let current = Snapshot(workbook: session.workbook, sheetIndex: session.sheetIndex,
                                       selection: session.selection)
                session.editing = nil
                session.replaceWorkbook(snapshot.workbook)
                session.sheetIndex = min(snapshot.sheetIndex, session.workbook.sheets.count - 1)
                session.selection = snapshot.selection
                session.registerUndo(restoring: current, actionName)
            }
        }
        undoManager.setActionName(actionName)
    }

    // MARK: - 格内编辑和公式栏

    /// 开始编辑活动格（合并单元格编辑的是左上角）。`text` 为 nil 时从格子里原来的写法开始。
    func beginEditing(_ origin: CellEditing.Origin, text: String? = nil) {
        let cursor = selection.cursor
        let address = sheet.merges.first { $0.contains(cursor) }?.start ?? cursor
        editing = CellEditing(address: address, text: text ?? rawText(at: address), origin: origin)
    }

    /// 提交编辑，然后光标挪 `rows` 行、`columns` 列（回车往下，Tab 往右）。文字没变就不算一次修改。
    func commitEditing(rows: Int = 0, columns: Int = 0) {
        guard let edit = editing else { return }
        editing = nil
        if edit.text != rawText(at: edit.address) {
            let index = sheetIndex
            apply(String(localized: "Typing")) { workbook in
                workbook.enter(CellInput.parse(edit.text, dateSystem: workbook.dateSystem), at: edit.address, sheet: index)
            }
        }
        moveCursor(rows: rows, columns: columns)
    }

    func cancelEditing() {
        editing = nil
    }

    /// 光标挪几格。从合并单元格往外走时跳过整块。
    func moveCursor(rows: Int, columns: Int, extend: Bool = false) {
        guard rows != 0 || columns != 0 else { return }
        let from = selection.cursor
        let merge = sheet.merges.first { $0.contains(from) }
        let row = rows > 0 ? (merge?.end.row ?? from.row) + rows : from.row + rows
        let column = columns > 0 ? (merge?.end.column ?? from.column) + columns : from.column + columns
        select(CellAddress(row: max(row, 0), column: max(column, 0)), extend: extend)
    }

    /// 格子里存的东西的原始写法：公式栏显示的、双击编辑时的、复制到 SkySheet 自己剪贴板上的都是它。
    func rawText(at address: CellAddress) -> String {
        sheet.cells[address].map { Self.rawText($0, styles: workbook.styles) } ?? ""
    }

    /// 公式显示原文；日期显示成日期；别的数字显示全精度（不按格式四舍五入），和 Excel 的公式栏一样。
    static func rawText(_ cell: Cell, styles: SkySheetCore.StyleTable) -> String {
        if let formula = cell.formula { return "=" + formula.source }
        switch cell.value {
        case .empty: return ""
        case .text(let text):
            // 像数字、公式的文字前面加 '，再输入一遍还是文字（和 Excel 一样）。
            return text.isEmpty || CellInput.parse(text) == .value(.text(text)) ? text : "'" + text
        case .bool(let flag): return flag ? "TRUE" : "FALSE"
        case .error(let error): return error.code
        case .number(let number):
            let code = styles.formatCode(forStyle: cell.styleIndex)
            guard ValueFormatter.isDateFormat(code) else { return ValueFormatter.general(number) }
            let dateCode = DecimalMath.isInteger(number) ? "yyyy/m/d" : "yyyy/m/d h:mm:ss"
            return ValueFormatter.format(cell.value, code: dateCode).text
        }
    }

    // MARK: - 清除、复制、粘贴

    /// Delete 键：清掉选区里的值和公式，样式留着。
    func clearSelection() {
        let range = selection.range
        let index = sheetIndex
        apply(String(localized: "Clear")) { $0.clearContents(range, sheet: index) }
    }

    /// 选区的原始写法，一格一格。
    func clipOfSelection() -> CellClip {
        let range = selection.range
        let rows = (range.start.row...range.end.row).map { row in
            (range.start.column...range.end.column).map { rawText(at: CellAddress(row: row, column: $0)) }
        }
        return CellClip(originRow: range.start.row, originColumn: range.start.column, rows: rows)
    }

    /// 粘贴一块：从选区左上角开始。只有一格、选区却是一块时，把整块填满（和 Excel 一样）。
    /// 从 SkySheet 复制来的公式按位置差平移引用；别处来的文字按输入的规矩解析。
    func paste(_ rows: [[String]], from origin: CellAddress?, actionName: String = String(localized: "Paste")) {
        guard !rows.isEmpty else { return }
        let target = selection.range
        let fills = rows.count == 1 && rows[0].count == 1 && (target.rowCount > 1 || target.columnCount > 1)
        var placements: [(address: CellAddress, text: String, source: CellAddress?)] = []
        if fills {
            for row in target.start.row...target.end.row {
                for column in target.start.column...target.end.column {
                    placements.append((CellAddress(row: row, column: column), rows[0][0], origin))
                }
            }
        } else {
            for (rowOffset, fields) in rows.enumerated() {
                for (columnOffset, text) in fields.enumerated() {
                    let address = CellAddress(row: target.start.row + rowOffset, column: target.start.column + columnOffset)
                    guard address.row < CellAddress.maxRows, address.column < CellAddress.maxColumns else { continue }
                    let source = origin.map { CellAddress(row: $0.row + rowOffset, column: $0.column + columnOffset) }
                    placements.append((address, text, source))
                }
            }
        }
        let index = sheetIndex
        apply(actionName) { workbook in
            for placement in placements {
                var text = placement.text
                if text.hasPrefix("="), text.count > 1, let source = placement.source {
                    text = "=" + ReferenceShift.shift(String(text.dropFirst()), rows: placement.address.row - source.row,
                                                      columns: placement.address.column - source.column)
                }
                workbook.enter(CellInput.parse(text, dateSystem: workbook.dateSystem), at: placement.address, sheet: index)
            }
        }
        if !fills, let last = placements.last {
            select(target.start)
            select(last.address, extend: true)
        }
    }

    // MARK: - sheet

    func renameSheet(_ index: Int, to name: String) throws {
        try apply(String(localized: "Rename Sheet")) { try $0.renameSheet(index, to: name) }
    }

    /// 复制一张，并切过去看复制出来的那张。
    func duplicateSheet(_ index: Int) {
        var copy = index + 1
        apply(String(localized: "Duplicate Sheet")) { copy = $0.duplicateSheet(index) }
        sheetIndex = copy
        resetSelection()
    }

    /// 删掉一张。删的是正在看的，就看它后面那张（没有就前面那张）。
    func deleteSheet(_ index: Int) throws {
        let wasShowing = index == sheetIndex
        try apply(String(localized: "Delete Sheet")) { try $0.deleteSheet(index) }
        if wasShowing {
            let visible = tabIndices
            sheetIndex = visible.first { $0 >= index } ?? visible.last ?? 0
            resetSelection()
        }
    }
}
