import AppKit
import SkySheetCore
import SkySheetDisplay
import SkySheetFiles

/// 鼠标、键盘、剪贴板、撤销、缩放（设计 8.2 节「基础编辑」）。
extension SpreadsheetView {
    // MARK: - 鼠标

    /// 点别的格子先提交正在编辑的；双击进入编辑（从格子里原来的写法开始）。
    override func mouseDown(with event: NSEvent) {
        if session.editing != nil { finishEditing(rows: 0, columns: 0) }
        window?.makeFirstResponder(self)
        guard let address = address(at: convert(event.locationInWindow, from: nil)) else { return }
        session.select(address, extend: event.modifierFlags.contains(.shift))
        if event.clickCount == 2, !event.modifierFlags.contains(.shift) { beginEditing(.editing) }
    }

    /// 拖着选一块。拖出主区时让主区自己往那边滚（autoscroll）。
    override func mouseDragged(with event: NSEvent) {
        guard session.editing == nil else { return }
        mainPane.autoscroll(with: event)
        guard let address = address(at: convert(event.locationInWindow, from: nil)) else { return }
        session.select(address, extend: true)
    }

    /// 在冻结区、行号列标上滚轮，也让主区滚。
    override func scrollWheel(with event: NSEvent) {
        scrollView.scrollWheel(with: event)
    }

    // MARK: - 键盘
    //
    // 走系统的按键绑定（interpretKeyEvents）：方向键、Tab、回车、Page Up/Down、⌘ 加方向键，按住 Shift 拉选区。
    // 能打出字的键走 insertText：开始编辑，把这一下按键转给编辑框（中文输入法要从第一下就接手）。

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 120 {   // F2：编辑活动格
            beginEditing(.editing)
            return
        }
        pendingKeyEvent = event
        interpretKeyEvents([event])
        pendingKeyEvent = nil
    }

    override func insertText(_ insertString: Any) {
        guard let event = pendingKeyEvent else { return }
        beginEditing(.typing, text: "", forwarding: event)
    }

    override func moveUp(_ sender: Any?) { session.moveCursor(rows: -1, columns: 0) }
    override func moveDown(_ sender: Any?) { session.moveCursor(rows: 1, columns: 0) }
    override func moveLeft(_ sender: Any?) { session.moveCursor(rows: 0, columns: -1) }
    override func moveRight(_ sender: Any?) { session.moveCursor(rows: 0, columns: 1) }
    override func moveUpAndModifySelection(_ sender: Any?) { session.moveCursor(rows: -1, columns: 0, extend: true) }
    override func moveDownAndModifySelection(_ sender: Any?) { session.moveCursor(rows: 1, columns: 0, extend: true) }
    override func moveLeftAndModifySelection(_ sender: Any?) { session.moveCursor(rows: 0, columns: -1, extend: true) }
    override func moveRightAndModifySelection(_ sender: Any?) { session.moveCursor(rows: 0, columns: 1, extend: true) }
    override func insertTab(_ sender: Any?) { session.moveCursor(rows: 0, columns: 1) }
    override func insertBacktab(_ sender: Any?) { session.moveCursor(rows: 0, columns: -1) }
    override func insertNewline(_ sender: Any?) {
        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        session.moveCursor(rows: shift ? -1 : 1, columns: 0)
    }
    override func pageDown(_ sender: Any?) { session.moveCursor(rows: visibleRowCount, columns: 0) }
    override func pageUp(_ sender: Any?) { session.moveCursor(rows: -visibleRowCount, columns: 0) }
    override func scrollPageDown(_ sender: Any?) { pageDown(sender) }
    override func scrollPageUp(_ sender: Any?) { pageUp(sender) }

    /// Delete 键（Mac 上的退格）和 fn+Delete：清掉选中格子的内容，样式留着。
    override func deleteBackward(_ sender: Any?) { session.clearSelection() }
    override func deleteForward(_ sender: Any?) { session.clearSelection() }

    /// ⌘↑ ⌘↓ ⌘← ⌘→：跳到有数据的边上（第一行 / 最后一行 / 第一列 / 最后一列）。
    override func moveToBeginningOfDocument(_ sender: Any?) { jump(row: 0) }
    override func moveToEndOfDocument(_ sender: Any?) { jump(row: session.sheet.cells.usedRange?.end.row ?? 0) }
    override func moveToBeginningOfLine(_ sender: Any?) { jump(column: 0) }
    override func moveToEndOfLine(_ sender: Any?) { jump(column: session.sheet.cells.usedRange?.end.column ?? 0) }
    override func moveToLeftEndOfLine(_ sender: Any?) { moveToBeginningOfLine(sender) }
    override func moveToRightEndOfLine(_ sender: Any?) { moveToEndOfLine(sender) }
    override func scrollToBeginningOfDocument(_ sender: Any?) { jump(row: 0, column: 0) }
    override func scrollToEndOfDocument(_ sender: Any?) {
        jump(row: session.sheet.cells.usedRange?.end.row ?? 0, column: session.sheet.cells.usedRange?.end.column ?? 0)
    }

    override func selectAll(_ sender: Any?) {
        session.selectAll()
    }

    private func jump(row: Int? = nil, column: Int? = nil) {
        let cursor = session.selection.cursor
        session.select(CellAddress(row: row ?? cursor.row, column: column ?? cursor.column))
    }

    private var visibleRowCount: Int {
        guard let canvas else { return 20 }
        return max(1, Int(scrollView.contentView.bounds.height / max(canvas.geometry.rows.defaultSize, 1)) - 1)
    }

    // MARK: - 剪贴板

    /// 复制两份：按显示出来的样子、制表符分隔的文字（贴到 Excel、腾讯文档里能还原成表格），
    /// 和 SkySheet 自己的格式（原始写法，粘回来不丢精度、公式平移引用）。
    @objc func copy(_ sender: Any?) {
        guard let canvas else { return }
        let range = session.selection.range
        let lines = (range.start.row...range.end.row).map { row in
            (range.start.column...range.end.column).map { column -> String in
                guard let cell = canvas.sheet.cells[CellAddress(row: row, column: column)] else { return "" }
                return Self.tabSafe(canvas.content(of: cell).0.text)
            }.joined(separator: "\t")
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
        if let clip = try? JSONEncoder().encode(session.clipOfSelection()) {
            pasteboard.setData(clip, forType: NSPasteboard.PasteboardType(CellClip.pasteboardType))
        }
    }

    /// 剪切 = 复制，然后清掉（第一版不做「粘贴时才移走」）。
    @objc func cut(_ sender: Any?) {
        copy(sender)
        session.clearSelection()
    }

    @objc func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(CellClip.pasteboardType)),
           let clip = try? JSONDecoder().decode(CellClip.self, from: data) {
            session.paste(clip.rows, from: CellAddress(row: clip.originRow, column: clip.originColumn))
        } else if let text = pasteboard.string(forType: .string) {
            session.paste(CSVReader.rows(in: text, delimiter: "\t"), from: nil)
        }
    }

    /// 菜单里的「Delete」：和 Delete 键一样。
    @objc func delete(_ sender: Any?) {
        session.clearSelection()
    }

    /// 带换行、制表符、引号的格子按 Excel 的写法用引号括起来，贴回表格软件时还是一格。
    private static func tabSafe(_ text: String) -> String {
        guard text.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r\n" || $0 == "\"" }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - 撤销
    //
    // 编辑框里按 ⌘Z 是取消这次编辑（打字本身不进文档的撤销栈）；不在编辑时交给文档的撤销管理器。

    @objc func undo(_ sender: Any?) {
        if session.editing != nil {
            cancelEditing()
        } else {
            undoManager?.undo()
        }
    }

    @objc func redo(_ sender: Any?) {
        guard session.editing == nil else { return }
        undoManager?.redo()
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            if session.editing != nil {
                item.title = String(localized: "Undo Typing")
                return true
            }
            item.title = undoManager?.undoMenuItemTitle ?? String(localized: "Undo")
            return undoManager?.canUndo ?? false
        case #selector(redo(_:)):
            item.title = undoManager?.redoMenuItemTitle ?? String(localized: "Redo")
            return session.editing == nil && (undoManager?.canRedo ?? false)
        case #selector(paste(_:)):
            let types = [NSPasteboard.PasteboardType.string, NSPasteboard.PasteboardType(CellClip.pasteboardType)]
            return NSPasteboard.general.availableType(from: types) != nil
        default:
            return true
        }
    }

    // MARK: - sheet 菜单（和页签右键菜单一样，对正在看的这张）

    @objc func renameSheet(_ sender: Any?) { SheetCommands.rename(session.sheetIndex, in: session, window: window) }
    @objc func duplicateSheet(_ sender: Any?) { SheetCommands.duplicate(session.sheetIndex, in: session) }
    @objc func deleteSheet(_ sender: Any?) { SheetCommands.delete(session.sheetIndex, in: session, window: window) }

    // MARK: - 缩放

    @objc func zoomIn(_ sender: Any?) { session.setZoom(session.zoom + 0.1) }
    @objc func zoomOut(_ sender: Any?) { session.setZoom(session.zoom - 0.1) }
    @objc func resetZoom(_ sender: Any?) { session.setZoom(1) }
}
