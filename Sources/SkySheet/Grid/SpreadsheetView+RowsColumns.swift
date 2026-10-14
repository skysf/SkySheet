import AppKit
import SkySheetCore
import SkySheetDisplay
import SkySheetFiles

/// 菜单里和行列有关的命令（2026-10-14 加，设计第 16 条）：插删行列、宽高、自动适应、隐藏、冻结。主菜单、列标行号的右键菜单、
/// 格子的右键菜单用同一组动作；标题（「Insert 3 Rows Above」）在 validateMenuItem 里按选区现算。
extension SpreadsheetView {
    // MARK: - 插删

    @objc func insertRowsAbove(_ sender: Any?) { insertLines(.rows, after: false) }
    @objc func insertRowsBelow(_ sender: Any?) { insertLines(.rows, after: true) }
    @objc func insertColumnsLeft(_ sender: Any?) { insertLines(.columns, after: false) }
    @objc func insertColumnsRight(_ sender: Any?) { insertLines(.columns, after: true) }
    @objc func deleteRows(_ sender: Any?) { deleteLines(.rows) }
    @objc func deleteColumns(_ sender: Any?) { deleteLines(.columns) }

    /// 菜单说的是哪几行（列）：选了几行就是几行；选的是整列时，行只算光标那一行（整列有一百多万行）。
    func targetLines(_ axis: SheetAxis) -> ClosedRange<Int> {
        let selection = session.selection
        if selection.isWhole(axis == .rows ? .columns : .rows) {
            let index = axis.index(of: selection.cursor)
            return index...index
        }
        return selection.lines(axis)
    }

    /// 选了几行就插几行，插在上面（下面），插完选中新插的那几行（和 Google 表格一样）。
    private func insertLines(_ axis: SheetAxis, after: Bool) {
        guard checkStructureLock() else { return }
        let lines = targetLines(axis)
        let position = after ? lines.upperBound + 1 : lines.lowerBound
        guard position < axis.limit else { return NSSound.beep() }
        let count = min(lines.count, axis.limit - position)
        guard perform({ try $0.shiftLines(.insert(count, at: position, axis)) }) else { return }
        selectLines(axis, through: position, extend: false)
        selectLines(axis, through: position + count - 1, extend: true)
    }

    private func deleteLines(_ axis: SheetAxis) {
        guard checkStructureLock() else { return }
        let lines = targetLines(axis)
        perform { try $0.shiftLines(.delete(lines, axis)) }
    }

    /// 这张表有图片、条件格式这类按位置指着格子的东西：不插删，说清楚为什么、怎么办。
    private func checkStructureLock() -> Bool {
        guard let lock = session.structureLockOfCurrentSheet else { return true }
        LayoutCommands.explainLock(lock, sheet: session.sheet.name, in: window)
        return false
    }

    /// 插删一次；不行就说为什么（工作簿没动）。做成了返回 true。
    @discardableResult
    private func perform(_ change: (SheetSession) throws -> StructureEditReport) -> Bool {
        do {
            _ = try change(session)
            return true
        } catch let error as StructureEditError {
            LayoutCommands.explain(error, in: window)
        } catch {
            NSSound.beep()
        }
        return false
    }

    // MARK: - 宽高、隐藏

    @objc func setColumnWidth(_ sender: Any?) {
        let columns = targetLines(.columns)
        let current = session.sheet.columns.first { ($0.first...$0.last).contains(columns.lowerBound) }?.width
            ?? canvas.map { SheetGeometry.columnWidth(forPixels: $0.geometry.columnWidth(columns.lowerBound) / session.zoom,
                                                      digitWidth: $0.digitWidth) } ?? 8.43
        LayoutCommands.askSize(.columns, lines: columns, current: current, in: window) { [session] width in
            session.setSize(width, .columns, lines: columns)
        }
    }

    @objc func setRowHeight(_ sender: Any?) {
        let rows = targetLines(.rows)
        let current = session.sheet.rowFormats[rows.lowerBound]?.height
            ?? session.sheet.defaultRowHeight ?? StyleTable.rowHeight(forFontSize: session.styles.baseFontSize)
        LayoutCommands.askSize(.rows, lines: rows, current: current, in: window) { [session] height in
            session.setSize(height, .rows, lines: rows)
        }
    }

    @objc func autoFitColumns(_ sender: Any?) { autoFit(.columns, lines: targetLines(.columns)) }
    @objc func autoFitRows(_ sender: Any?) { autoFit(.rows, lines: targetLines(.rows)) }
    @objc func hideColumns(_ sender: Any?) { session.setHidden(true, .columns, lines: targetLines(.columns)) }
    @objc func hideRows(_ sender: Any?) { session.setHidden(true, .rows, lines: targetLines(.rows)) }
    @objc func unhideColumns(_ sender: Any?) { unhide(.columns) }
    @objc func unhideRows(_ sender: Any?) { unhide(.rows) }

    /// 取消隐藏选区里藏着的（和 Excel 一样：要选上藏着的那几列两边的列）。
    private func unhide(_ axis: SheetAxis) {
        let hidden = session.sheet.hiddenLines(axis, in: session.selection.lines(axis))
        guard let first = hidden.first, let last = hidden.last else { return }
        session.setHidden(false, axis, lines: first...last)
    }

    // MARK: - 冻结

    @objc func freezeTopRow(_ sender: Any?) { session.freeze(rows: 1, columns: 0) }
    @objc func freezeFirstColumn(_ sender: Any?) { session.freeze(rows: 0, columns: 1) }
    @objc func unfreezePanes(_ sender: Any?) { session.freeze(rows: 0, columns: 0) }

    /// 冻结到选区：选的是整行，冻结它上面的行；整列，冻结它左边的列；一格，冻结它上面的行和左边的列（和 Excel 一样）。
    @objc func freezePanes(_ sender: Any?) {
        let (rows, columns) = freezeTarget
        session.freeze(rows: rows, columns: columns)
    }

    private var freezeTarget: (rows: Int, columns: Int) {
        let selection = session.selection
        switch selection.kind {
        case .rows: return (selection.range.start.row, 0)
        case .columns: return (0, selection.range.start.column)
        case .cells: return (selection.cursor.row, selection.cursor.column)
        }
    }

    // MARK: - 右键菜单

    /// 列标（行号）的右键菜单。
    func headerMenu(_ axis: SheetAxis) -> NSMenu {
        // 插删的标题按选区现算（validateRowsColumnsItem），这里先空着。
        contextMenu(axis == .columns
            ? [(#selector(insertColumnsLeft(_:)), ""), (#selector(insertColumnsRight(_:)), ""), (#selector(deleteColumns(_:)), ""),
               (nil, ""), (#selector(setColumnWidth(_:)), String(localized: "Column Width…")),
               (#selector(autoFitColumns(_:)), String(localized: "AutoFit Column Width")),
               (nil, ""), (#selector(hideColumns(_:)), String(localized: "Hide Columns")),
               (#selector(unhideColumns(_:)), String(localized: "Unhide Columns"))]
            : [(#selector(insertRowsAbove(_:)), ""), (#selector(insertRowsBelow(_:)), ""), (#selector(deleteRows(_:)), ""),
               (nil, ""), (#selector(setRowHeight(_:)), String(localized: "Row Height…")),
               (#selector(autoFitRows(_:)), String(localized: "AutoFit Row Height")),
               (nil, ""), (#selector(hideRows(_:)), String(localized: "Hide Rows")),
               (#selector(unhideRows(_:)), String(localized: "Unhide Rows"))])
    }

    /// 一串菜单项（动作为 nil 的是分隔线），都发给这个表格视图。
    private func contextMenu(_ entries: [(Selector?, String)]) -> NSMenu {
        let menu = NSMenu()
        for (action, title) in entries {
            guard let action else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    /// 格子的右键菜单：点在选区外先选中那一格。
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let address = address(at: convert(event.locationInWindow, from: nil)) else { return nil }
        if !session.selection.range.contains(address) {
            prepareForMouse()
            session.select(address)
        }
        return contextMenu([
            (#selector(cut(_:)), String(localized: "Cut")), (#selector(copy(_:)), String(localized: "Copy")),
            (#selector(paste(_:)), String(localized: "Paste")), (#selector(delete(_:)), String(localized: "Clear Contents")),
            (nil, ""),
            (#selector(insertRowsAbove(_:)), ""), (#selector(insertColumnsLeft(_:)), ""),
            (#selector(deleteRows(_:)), ""), (#selector(deleteColumns(_:)), ""),
            (nil, ""),
            (#selector(mergeCells(_:)), String(localized: "Merge Cells")),
            (#selector(unmergeCells(_:)), String(localized: "Unmerge Cells")),
        ])
    }

    // MARK: - 菜单的标题和能不能点

    /// 行列这一组菜单项：认得就返回能不能点（顺带改好标题），不认得返回 nil。
    func validateRowsColumnsItem(_ item: NSMenuItem) -> Bool? {
        let editing = session.editing != nil
        let rows = targetLines(.rows)
        let columns = targetLines(.columns)
        switch item.action {
        case #selector(insertRowsAbove(_:)):
            item.title = rows.count == 1 ? String(localized: "Insert 1 Row Above") : String(localized: "Insert \(rows.count) Rows Above")
        case #selector(insertRowsBelow(_:)):
            item.title = rows.count == 1 ? String(localized: "Insert 1 Row Below") : String(localized: "Insert \(rows.count) Rows Below")
        case #selector(insertColumnsLeft(_:)):
            item.title = columns.count == 1 ? String(localized: "Insert 1 Column Left")
                                            : String(localized: "Insert \(columns.count) Columns Left")
        case #selector(insertColumnsRight(_:)):
            item.title = columns.count == 1 ? String(localized: "Insert 1 Column Right")
                                            : String(localized: "Insert \(columns.count) Columns Right")
        case #selector(deleteRows(_:)):
            item.title = rows.count == 1 ? String(localized: "Delete Row \(rows.lowerBound + 1)")
                                         : String(localized: "Delete Rows \(rows.lowerBound + 1)–\(rows.upperBound + 1)")
        case #selector(deleteColumns(_:)):
            let first = CellAddress.columnName(columns.lowerBound)
            let last = CellAddress.columnName(columns.upperBound)
            item.title = columns.count == 1 ? String(localized: "Delete Column \(first)")
                                            : String(localized: "Delete Columns \(first)–\(last)")
        case #selector(setColumnWidth(_:)), #selector(setRowHeight(_:)), #selector(autoFitColumns(_:)),
             #selector(autoFitRows(_:)), #selector(hideColumns(_:)), #selector(hideRows(_:)):
            break
        case #selector(unhideColumns(_:)):
            return !editing && !session.sheet.hiddenLines(.columns, in: session.selection.columns).isEmpty
        case #selector(unhideRows(_:)):
            return !editing && !session.sheet.hiddenLines(.rows, in: session.selection.rows).isEmpty
        case #selector(freezeTopRow(_:)):
            item.state = session.sheet.frozen == FrozenPanes(rows: 1, columns: 0) ? .on : .off
        case #selector(freezeFirstColumn(_:)):
            item.state = session.sheet.frozen == FrozenPanes(rows: 0, columns: 1) ? .on : .off
        case #selector(freezePanes(_:)):
            let target = freezeTarget
            return !editing && (target.rows > 0 || target.columns > 0)
        case #selector(unfreezePanes(_:)):
            return !editing && session.sheet.frozen != nil
        default:
            return nil
        }
        return !editing
    }
}
