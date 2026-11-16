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

    var sheetID: Int
    var address: CellAddress
    var text: String
    var origin: Origin
    let originalText: String
    let sheetNames: [Int: String]
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
    func apply(_ actionName: String, author: AIAuthorship.Mark.Author = .user, groupUndo: Bool = false,
               _ change: (inout Workbook) throws -> Void) rethrows {
        let before = Snapshot(workbook: workbook, sheetIndex: sheetIndex, selection: selection)
        var changed = workbook
        try change(&changed)
        guard changed != workbook else { return }
        // 文件里 SkySheet 写不回去的公式占着的格子（算不出来的共享公式组、模拟运算表），内容不能改：整个不做，
        // 说为什么（PR #17 第一轮审查第 3–5 条）。AI 的改动在 AIContext.change 里先拒绝了，到不了这里。
        if let locked = changed.lockedFormulaChange(since: workbook) {
            refusedChange?(locked)
            return
        }
        // 内容被改写过的格子，文件里的 `<f>` 记录作废，以后不会再对上（PR #17 第二轮审查第 2 条）。AI 的改动也从这里过；
        // ⌘Z 撤销不经这里，换回的是改之前的那一份，记录跟着内容一起回来。整轮撤销经这里换回快照，锁住的格子这一轮里
        // 改不了，记录不受影响（retireReplacedFormulas，最后一次复查）。
        changed.retireReplacedFormulas(since: workbook)
        let edited = Self.editedSheets(changed, comparedTo: workbook)
        Recalculator.recalculate(&changed, options: RecalcOptions(cache: recalcCache))
        Self.sign(&changed, sheets: edited, author: author)
        replaceWorkbook(changed)
        // 关窗要同步结束这一步；放在差异检查之后，避免空分组让干净文档出现保存确认。
        if groupUndo {
            AIUndoGrouping.step(undoManager) { registerUndo(restoring: before, actionName) }
        } else {
            registerUndo(restoring: before, actionName)
        }
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
        let original = rawText(at: address)
        editing = CellEditing(sheetID: sheet.id, address: address, text: text ?? original, origin: origin,
                              originalText: original, sheetNames: Dictionary(uniqueKeysWithValues: workbook.sheets.map { ($0.id, $0.name) }))
    }

    /// 提交编辑，然后光标挪 `rows` 行、`columns` 列（回车往下，Tab 往右）。文字没变就不算一次修改。
    func commitEditing(rows: Int = 0, columns: Int = 0, groupUndo: Bool = false) {
        guard let edit = editing else { return }
        editing = nil
        // AI 可在输入期间删表或让数组下标挪动；编号消失就丢弃，绝不能落到后继表。
        guard let index = workbook.sheets.firstIndex(where: { $0.id == edit.sheetID }) else { return }
        // 没改字就保留后台已重写的格子；改过的公式按开始编辑时的表编号跟随改名。
        if edit.text != edit.originalText {
            var input = CellInput.parse(edit.text, dateSystem: workbook.dateSystem)
            if case .formula(let formula) = input {
                let renames = workbook.sheets.compactMap { sheet -> (from: String, to: String)? in
                    guard let old = edit.sheetNames[sheet.id], old != sheet.name else { return nil }
                    return (old, sheet.name)
                }
                input = .formula(FormulaRewriter.renameSheets(in: formula, renames: renames))
            }
            apply(String(localized: "Typing"), groupUndo: groupUndo) { workbook in
                workbook.enter(input, at: edit.address, sheet: index)
            }
        }
        moveCursor(rows: rows, columns: columns)
    }

    func cancelEditing() {
        editing = nil
    }

    /// 光标挪几格。从合并单元格往外走时跳过整块；藏起来的行、列跳过去，和 Excel 一样。
    func moveCursor(rows: Int, columns: Int, extend: Bool = false) {
        guard rows != 0 || columns != 0 else { return }
        let from = selection.cursor
        let merge = sheet.merges.first { $0.contains(from) }
        var row = max(rows > 0 ? (merge?.end.row ?? from.row) + rows : from.row + rows, 0)
        var column = max(columns > 0 ? (merge?.end.column ?? from.column) + columns : from.column + columns, 0)
        if rows != 0 { row = visibleLine(.rows, from: row, step: rows > 0 ? 1 : -1) ?? from.row }
        if columns != 0 { column = visibleLine(.columns, from: column, step: columns > 0 ? 1 : -1) ?? from.column }
        select(CellAddress(row: row, column: column), extend: extend)
    }

    /// 从 `index` 起往 `step` 那边找第一行（列）没藏起来的；一直到表的边上都藏着就是 nil（光标不动）。
    private func visibleLine(_ axis: SheetAxis, from index: Int, step: Int) -> Int? {
        var line = min(index, axis.limit - 1)
        while sheet.isHidden(axis, line) {
            line += step
            guard line >= 0, line < axis.limit else { return nil }
        }
        return line
    }

    /// 公式栏和双击编辑时用的写法；内部复制直接取 CellValue，不经过这里。
    func rawText(at address: CellAddress) -> String {
        // 方向键每次移动都会读公式栏；一次取同一本，避免为格子、样式和日期系统反复复制大值、登记观测。
        let book = workbook
        guard let cell = book.sheets[sheetIndex].cells[address] else { return "" }
        return Self.rawText(cell, styles: book.styles, dateSystem: book.dateSystem)
    }

    /// 公式显示原文；日期显示成日期；别的数字显示全精度（不按格式四舍五入），和 Excel 的公式栏一样。
    static func rawText(_ cell: Cell, styles: SkySheetCore.StyleTable, dateSystem: DateSystem) -> String {
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
            guard ValueFormatter.isCalendarDateFormat(code, for: number) else { return ValueFormatter.general(number) }
            let dateCode = DecimalMath.isInteger(number) ? "yyyy/m/d" : "yyyy/m/d h:mm:ss"
            return ValueFormatter.format(cell.value, code: dateCode, dateSystem: dateSystem).text
        }
    }

    // MARK: - 清除、复制、粘贴

    /// Delete 键：清掉选区里的值和公式，样式留着。
    func clearSelection() {
        let range = selection.range
        let index = sheetIndex
        apply(String(localized: "Clear")) { $0.clearContents(range, sheet: index) }
    }

    /// 两份复制数据共用的范围预检；必须先检查面积再展开格子。
    func checkedCopyRange() throws -> CellRange {
        let range = selectedCells ?? CellRange(selection.cursor)
        try CopyLimit.check(range)
        return range
    }

    func clipOfSelection() throws -> CellClip {
        commitEditing()
        let range = try checkedCopyRange()
        let formats = workbook.styles
        let entries = sheet.cells.entries(in: range).compactMap { address, cell -> CellClip.Entry? in
            guard cell.value != .empty || cell.formula != nil else { return nil }
            return CellClip.Entry(cell, row: address.row - range.start.row, column: address.column - range.start.column,
                                  numberFormat: formats.formatCode(forStyle: cell.styleIndex))
        }
        return CellClip(origin: range.start, rowCount: range.rowCount, columnCount: range.columnCount,
                        entries: entries, dateSystem: workbook.dateSystem)
    }

    /// 从 SkySheet 来的稀疏矩形也会清掉对应的空位；数字格式只给常规格，和打字的规则相同。
    func paste(_ rows: [[String]], from origin: CellAddress?, actionName: String = String(localized: "Paste")) throws {
        guard !rows.isEmpty, let width = rows.map(\.count).max(), width > 0 else { return }
        try CopyLimit.check(rows: rows.count, columns: width)
        var entries: [CellAddress: PasteCell] = [:]
        for (row, fields) in rows.enumerated() {
            for (column, text) in fields.enumerated() {
                entries[CellAddress(row: row, column: column)] = PasteCell(input: CellInput.parse(text, dateSystem: workbook.dateSystem))
            }
        }
        try paste(rows: rows.count, columns: width, entries: entries, from: origin, actionName: actionName, clearMissing: false)
    }

    func paste(_ clip: CellClip, actionName: String = String(localized: "Paste")) throws {
        try CopyLimit.check(rows: clip.rowCount, columns: clip.columnCount)
        guard clip.originRow >= 0, clip.originColumn >= 0,
              clip.rowCount <= CellAddress.maxRows - clip.originRow,
              clip.columnCount <= CellAddress.maxColumns - clip.originColumn else { throw CopyLimit.exceeded }
        var entries: [CellAddress: PasteCell] = [:]
        for entry in clip.entries {
            guard (0..<clip.rowCount).contains(entry.row), (0..<clip.columnCount).contains(entry.column) else { throw CopyLimit.exceeded }
            var value = entry.value
            var numberFormat = entry.numberFormat
            if entry.formula == nil, clip.dateSystem != workbook.dateSystem,
               let code = entry.numberFormat, case .number(let number) = value,
               let dateCode = ValueFormatter.calendarDateSection(code, for: number) {
                let shifted = number + (clip.dateSystem == .from1900 ? -1462 : 1462)
                // 目标系统里没有这一天就不换算、原样粘贴（设计第十五节）；换算了，常规格只套生效的日期段：
                // 整份格式跟过去，换算后的数会按条件、正负零重新选段，日期变回数字，复制回去也换不回来。
                if Self.isCalendarDay(shifted, in: workbook.dateSystem) {
                    value = .number(shifted)
                    numberFormat = dateCode
                }
            }
            entries[CellAddress(row: entry.row, column: entry.column)] = PasteCell(
                input: entry.formula.map(CellInput.formula) ?? .value(value), numberFormat: numberFormat)
        }
        try paste(rows: clip.rowCount, columns: clip.columnCount, entries: entries,
                  from: CellAddress(row: clip.originRow, column: clip.originColumn), actionName: actionName)
    }

    /// 换算后的序列号在这个日期系统里是不是真有的一天：1904 不早于 1904-01-01；1900 不是「1900-01-00」，
    /// 也不是 Excel 虚构的 1900-02-29。
    private static func isCalendarDay(_ serial: Decimal, in system: DateSystem) -> Bool {
        switch system {
        case .from1904: serial >= 0
        case .from1900: serial >= 1 && !(serial >= 60 && serial < 61)
        }
    }

    private struct PasteCell {
        var input: CellInput
        var numberFormat: String? = nil
    }

    private func paste(rows: Int, columns: Int, entries: [CellAddress: PasteCell], from origin: CellAddress?, actionName: String,
                       clearMissing: Bool = true) throws {
        commitEditing()
        let target = selection.kind == .cells ? selection.range : (selectedCells ?? CellRange(selection.range.start))
        let fills = rows == 1 && columns == 1 && (target.rowCount > 1 || target.columnCount > 1)
        if fills { try CopyLimit.check(target) }
        let end = fills ? target.end : CellAddress(row: min(target.start.row + rows - 1, CellAddress.maxRows - 1),
                                                 column: min(target.start.column + columns - 1, CellAddress.maxColumns - 1))
        let destination = CellRange(target.start, end)
        let index = sheetIndex
        var pastedEnd = end
        apply(actionName) { workbook in
            func enter(_ cell: PasteCell, at address: CellAddress, source: CellAddress?) {
                var input = cell.input
                if case .formula(let formula) = input, let source {
                    input = .formula(ReferenceShift.shift(formula, rows: address.row - source.row,
                                                         columns: address.column - source.column))
                }
                workbook.enter(input, at: address, sheet: index)
                let anchor = workbook.sheets[index].merges.first { $0.contains(address) }?.start ?? address
                if let code = cell.numberFormat, var pasted = workbook.sheets[index].cells[anchor],
                   workbook.styles.numberFormatID(forStyle: pasted.styleIndex) == 0 {
                    pasted.styleIndex = workbook.styleIndex(basedOn: pasted.styleIndex, numberFormat: .custom(code))
                    workbook.sheets[index].cells[anchor] = pasted
                }
            }
            if fills {
                let cell = entries[CellAddress(row: 0, column: 0)] ?? PasteCell(input: .clear)
                for row in destination.start.row...destination.end.row {
                    for column in destination.start.column...destination.end.column {
                        enter(cell, at: CellAddress(row: row, column: column), source: origin)
                    }
                }
            } else if clearMissing {
                // 稀疏的是剪贴板存储，粘贴仍按行列顺序走空位；多个目标落在同一合并格时也保持旧语义。
                // 上限已检查，逐格处理但不建立密集数组，内存不会随矩形多出一份 placements。
                for row in destination.start.row...destination.end.row {
                    for column in destination.start.column...destination.end.column {
                        let offset = CellAddress(row: row - target.start.row, column: column - target.start.column)
                        let cell = entries[offset] ?? PasteCell(input: .clear)
                        let source = origin.map { CellAddress(row: $0.row + offset.row, column: $0.column + offset.column) }
                        enter(cell, at: CellAddress(row: row, column: column), source: source)
                    }
                }
            } else {
                // 外部 TSV 的短行没有那些字段，不等于显式空格；只改实际提供的字段，并保持行列顺序。
                for (offset, cell) in entries.sorted(by: { $0.key < $1.key }) {
                    let address = CellAddress(row: target.start.row + offset.row, column: target.start.column + offset.column)
                    guard destination.contains(address) else { continue }
                    let source = origin.map { CellAddress(row: $0.row + offset.row, column: $0.column + offset.column) }
                    enter(cell, at: address, source: source)
                    pastedEnd = address
                }
            }
        }
        if !fills {
            select(target.start)
            select(pastedEnd, extend: true)
        }
    }

    // MARK: - sheet

    func renameSheet(_ index: Int, to name: String) throws {
        try apply(String(localized: "Rename Sheet")) { try $0.renameSheet(index, to: name) }
    }

    /// 复制一张，并切过去看复制出来的那张。
    func duplicateSheet(_ index: Int) {
        commitEditing()
        var copy = index + 1
        apply(String(localized: "Duplicate Sheet")) { copy = $0.duplicateSheet(index) }
        sheetIndex = copy
        resetSelection()
    }

    /// 删掉一张。删的是正在看的，就看它后面那张（没有就前面那张）。
    func deleteSheet(_ index: Int) throws {
        commitEditing()
        let wasShowing = index == sheetIndex
        try apply(String(localized: "Delete Sheet")) { try $0.deleteSheet(index) }
        if wasShowing {
            let visible = tabIndices
            sheetIndex = visible.first { $0 >= index } ?? visible.last ?? 0
            resetSelection()
        }
    }
}
