import AppKit
import SkySheetCore
import SkySheetDisplay

/// 鼠标、键盘、复制、缩放。M2 只看不改（设计第十三节），编辑在 M3。
extension SpreadsheetView {
    // MARK: - 鼠标

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let address = address(at: convert(event.locationInWindow, from: nil)) else { return }
        session.select(address, extend: event.modifierFlags.contains(.shift))
    }

    /// 拖着选一块。拖出主区时让主区自己往那边滚（autoscroll）。
    override func mouseDragged(with event: NSEvent) {
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

    override func keyDown(with event: NSEvent) {
        interpretKeyEvents([event])
    }

    override func moveUp(_ sender: Any?) { move(rows: -1, columns: 0) }
    override func moveDown(_ sender: Any?) { move(rows: 1, columns: 0) }
    override func moveLeft(_ sender: Any?) { move(rows: 0, columns: -1) }
    override func moveRight(_ sender: Any?) { move(rows: 0, columns: 1) }
    override func moveUpAndModifySelection(_ sender: Any?) { move(rows: -1, columns: 0, extend: true) }
    override func moveDownAndModifySelection(_ sender: Any?) { move(rows: 1, columns: 0, extend: true) }
    override func moveLeftAndModifySelection(_ sender: Any?) { move(rows: 0, columns: -1, extend: true) }
    override func moveRightAndModifySelection(_ sender: Any?) { move(rows: 0, columns: 1, extend: true) }
    override func insertTab(_ sender: Any?) { move(rows: 0, columns: 1) }
    override func insertBacktab(_ sender: Any?) { move(rows: 0, columns: -1) }
    override func insertNewline(_ sender: Any?) { move(rows: 1, columns: 0) }
    override func pageDown(_ sender: Any?) { move(rows: visibleRowCount, columns: 0) }
    override func pageUp(_ sender: Any?) { move(rows: -visibleRowCount, columns: 0) }
    override func scrollPageDown(_ sender: Any?) { pageDown(sender) }
    override func scrollPageUp(_ sender: Any?) { pageUp(sender) }

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

    private func move(rows: Int, columns: Int, extend: Bool = false) {
        let from = session.selection.cursor
        // 从合并单元格里往外走时，跳过整块（往下走从合并块的下沿出去）。
        let merge = canvas?.merge(containing: from)
        let row = rows > 0 ? (merge?.end.row ?? from.row) + rows : from.row + rows
        let column = columns > 0 ? (merge?.end.column ?? from.column) + columns : from.column + columns
        session.select(CellAddress(row: max(row, 0), column: max(column, 0)), extend: extend)
    }

    private func jump(row: Int? = nil, column: Int? = nil) {
        let cursor = session.selection.cursor
        session.select(CellAddress(row: row ?? cursor.row, column: column ?? cursor.column))
    }

    private var visibleRowCount: Int {
        guard let canvas else { return 20 }
        return max(1, Int(scrollView.contentView.bounds.height / max(canvas.geometry.rows.defaultSize, 1)) - 1)
    }

    // MARK: - 复制、缩放

    /// 复制选中的格子：按显示出来的样子，制表符分隔、一行一行（贴到 Excel、腾讯文档里能还原成表格）。
    @objc func copy(_ sender: Any?) {
        guard let canvas else { return }
        let range = session.selection.range
        var lines: [String] = []
        for row in range.start.row...range.end.row {
            var fields: [String] = []
            for column in range.start.column...range.end.column {
                guard let cell = canvas.sheet.cells[CellAddress(row: row, column: column)] else {
                    fields.append("")
                    continue
                }
                fields.append(canvas.content(of: cell).0.text.replacingOccurrences(of: "\t", with: " "))
            }
            lines.append(fields.joined(separator: "\t"))
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    @objc func zoomIn(_ sender: Any?) { session.setZoom(session.zoom + 0.1) }
    @objc func zoomOut(_ sender: Any?) { session.setZoom(session.zoom - 0.1) }
    @objc func resetZoom(_ sender: Any?) { session.setZoom(1) }
}
