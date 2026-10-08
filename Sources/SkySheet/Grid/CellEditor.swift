import AppKit
import SkySheetCore
import SkySheetDisplay

/// 格内的编辑框：盖在活动格上的一个文字框（设计 8.2 节「基础编辑」）。
/// 文字和公式栏同步：两边都读写 `session.editing`。打字超出格子时往右变宽，和 Excel 一样。
@MainActor
final class CellEditor: NSTextField, NSTextFieldDelegate {
    weak var spreadsheet: SpreadsheetView?

    init() {
        super.init(frame: .zero)
        isBordered = false
        isBezeled = false
        focusRingType = .none
        drawsBackground = true
        backgroundColor = .white
        textColor = .black
        usesSingleLineMode = false
        cell?.wraps = false
        cell?.isScrollable = true
        // 打字的撤销不进文档的撤销栈：编辑中按 ⌘Z 是取消这次编辑（SpreadsheetView.undo）。
        cell?.allowsUndo = false
        wantsLayer = true
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        delegate = self
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// 摆到格子上：`rect` 是格子在 SpreadsheetView 里的位置，`limit` 是最多能往右长到哪。
    func place(over rect: CGRect, limit: CGFloat, font: NSFont) {
        if self.font != font { self.font = font }
        let textWidth = (stringValue as NSString).size(withAttributes: [.font: font]).width + 12
        let width = min(max(rect.width, textWidth), max(rect.width, limit - rect.minX))
        frame = CGRect(x: rect.minX - 1, y: rect.minY - 1, width: width + 2, height: max(rect.height, font.boundingRectForFont.height) + 2)
    }

    // MARK: - 打字、提交、取消

    func controlTextDidChange(_ notification: Notification) {
        spreadsheet?.session.editing?.text = stringValue
        spreadsheet?.placeEditor()
    }

    /// 回车往下、Shift+回车往上、Tab 往右、Shift+Tab 往左、Esc 取消、Option+回车在格子里换行。
    /// 「输入」模式（直接打字开始的）方向键也是提交并移动；「编辑」模式（双击、F2）方向键在文字里移光标。
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let spreadsheet else { return false }
        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        let typing = spreadsheet.session.editing?.origin == .typing
        switch selector {
        case #selector(insertNewline(_:)): spreadsheet.finishEditing(rows: shift ? -1 : 1, columns: 0)
        case #selector(insertTab(_:)): spreadsheet.finishEditing(rows: 0, columns: 1)
        case #selector(insertBacktab(_:)): spreadsheet.finishEditing(rows: 0, columns: -1)
        case #selector(cancelOperation(_:)): spreadsheet.cancelEditing()
        case #selector(insertNewlineIgnoringFieldEditor(_:)):
            textView.insertText("\n", replacementRange: textView.selectedRange())
        case #selector(moveUp(_:)) where typing: spreadsheet.finishEditing(rows: -1, columns: 0)
        case #selector(moveDown(_:)) where typing: spreadsheet.finishEditing(rows: 1, columns: 0)
        case #selector(moveLeft(_:)) where typing: spreadsheet.finishEditing(rows: 0, columns: -1)
        case #selector(moveRight(_:)) where typing: spreadsheet.finishEditing(rows: 0, columns: 1)
        default: return false
        }
        return true
    }
}

/// 开始、结束编辑，以及编辑框跟着格子走。
extension SpreadsheetView {
    /// `event` 是开始编辑的那一下按键：转给编辑框处理，中文输入法才能接着拼音往下打。
    func beginEditing(_ origin: CellEditing.Origin, text: String? = nil, forwarding event: NSEvent? = nil) {
        session.beginEditing(origin, text: text)
        editingChanged()
        window?.makeFirstResponder(editor)
        guard let field = editor.currentEditor() as? NSTextView else { return }
        field.selectedRange = NSRange(location: (editor.stringValue as NSString).length, length: 0)
        if let event { field.keyDown(with: event) }
    }

    func finishEditing(rows: Int, columns: Int) {
        session.commitEditing(rows: rows, columns: columns)
        window?.makeFirstResponder(self)
    }

    func cancelEditing() {
        session.cancelEditing()
        window?.makeFirstResponder(self)
    }

    /// session.editing 变了（开始、结束、公式栏那边在打字）：显示或藏起编辑框，文字跟上。
    func editingChanged() {
        guard let edit = session.editing else {
            if !editor.isHidden {
                editor.isHidden = true
                editor.stringValue = ""
            }
            return
        }
        if editor.isHidden { editor.isHidden = false }
        // 编辑框自己在打字时不回写，免得把光标位置和输入法的拼音冲掉。
        let isTypingHere = editor.currentEditor() != nil && edit.origin != .formulaBar
        if !isTypingHere, editor.stringValue != edit.text { editor.stringValue = edit.text }
        placeEditor()
    }

    /// 编辑框摆到正在编辑的格子上（滚动、缩放、打字变宽时都要重摆）。
    func placeEditor() {
        guard let canvas, let edit = session.editing else { return }
        let range = canvas.merge(containing: edit.address) ?? CellRange(edit.address)
        let rect = viewRect(of: range)
        let style = canvas.styles.style(canvas.sheet.cells[edit.address]?.styleIndex ?? 0)
        let font = canvas.fonts.font(style.font, points: style.font.size * SheetGeometry.pixelsPerPoint * session.zoom)
        editor.place(over: rect, limit: bounds.width, font: font)
    }

    /// 一块格子在 SpreadsheetView 里的位置：冻结区不加滚动距离，其余减去（address(at:) 反过来）。
    func viewRect(of range: CellRange) -> CGRect {
        guard let canvas else { return .zero }
        let sheetRect = canvas.rect(of: range)
        let x = rowHeaderWidth + sheetRect.minX - (range.start.column < canvas.frozenColumns ? 0 : scrollOffset.x)
        let y = Self.columnHeaderHeight + sheetRect.minY - (range.start.row < canvas.frozenRows ? 0 : scrollOffset.y)
        return CGRect(x: x, y: y, width: sheetRect.width, height: sheetRect.height)
    }
}
