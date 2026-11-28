import AppKit
import SkySheetCore

extension SpreadsheetView {
    /// 点击网格时保留原来的文本框和插入点。页签有时先拿走焦点，此时沿用刚点好的引用或末尾。
    private var formulaInput: (field: NSTextField, text: String, selection: NSRange)? {
        // 在公式栏里只选中旧引用、还没打过字时，AppKit 尚未通知 controlTextDidBeginEditing。
        if let bar = formulaField, let native = bar.currentEditor() as? NSTextView, native === window?.firstResponder {
            guard native.string.hasPrefix("="), !native.hasMarkedText() else { return nil }
            return (bar, native.string, native.selectedRange())
        }
        guard let edit = session.editing, edit.text.hasPrefix("=") else { return nil }
        let field = edit.origin == .formulaBar ? formulaField : editor
        guard let field else { return nil }
        let native = field.currentEditor() as? NSTextView
        guard native?.hasMarkedText() != true else { return nil }
        let selection = native?.selectedRange() ?? edit.picked?.insertion.caret ?? NSRange(location: edit.text.utf16.count, length: 0)
        return (field, edit.text, selection)
    }

    var canPickReference: Bool {
        guard let input = formulaInput else { return false }
        return FormulaReferenceEdit.slot(in: input.text, selection: input.selection, previous: session.editing?.picked?.insertion) != nil
    }

    private func activeDraft(for field: NSTextField) -> CellEditing? {
        if field === formulaField {
            if session.editing == nil { session.beginEditing(.formulaBar) }
            else if session.editing?.origin != .formulaBar { session.editing?.origin = .formulaBar }
        }
        return session.editing
    }

    func selectSheetTab(_ index: Int) {
        guard session.sheetIndex != index else { return }
        guard let input = formulaInput, canPickReference, let formulaField, activeDraft(for: input.field) != nil else {
            session.showSheet(index)
            return
        }
        // 原格不在屏幕上时把键盘交给公式栏，后续的运算符、回车和 Esc 仍然编辑同一个格子。
        session.editing?.origin = .formulaBar
        session.showSheet(index, pickingReference: true)
        display(input.text, selection: input.selection, in: formulaField)
        editingChanged()
    }

    private var currentPick: CellEditing.Pick? {
        guard let pick = session.editing?.picked, pick.sheetID == session.sheet.id else { return nil }
        return pick
    }

    @discardableResult
    func pickCellReference(_ address: CellAddress, extend: Bool) -> Bool {
        guard session.editing != nil || formulaField?.currentEditor() != nil else { return false }
        let cell = canvas?.merge(containing: address)?.start ?? address
        let last = currentPick?.selection
        let anchor = extend && last?.kind == .cells ? last?.anchor ?? cell : cell
        return pick(Selection(anchor: anchor, cursor: cell))
    }

    func pickLineReference(_ axis: SheetAxis, index: Int, extend: Bool) -> Bool {
        guard session.editing != nil || formulaField?.currentEditor() != nil else { return false }
        let kind: Selection.Kind = axis == .columns ? .columns : .rows
        let cell = axis.moving(session.selection.cursor, to: index)
        let last = currentPick?.selection
        let anchor = extend && last?.kind == kind ? last?.anchor ?? cell : cell
        return pick(Selection(lines: kind, anchor: anchor, cursor: cell))
    }

    private func pick(_ selection: Selection) -> Bool {
        guard let input = formulaInput else { return false }
        let draft = session.editing
        let foreign = draft.map { $0.sheetID != session.sheet.id } ?? false
        let sheetName = foreign ? session.sheet.name : nil
        guard var change = FormulaReferenceEdit.picking(selection.range, sheet: sheetName, in: input.text,
                                                       selection: input.selection, previous: draft?.picked?.insertion),
              var edit = activeDraft(for: input.field) else { return false }
        if edit.referenceRevision != session.revision {
            let current = Dictionary(uniqueKeysWithValues: session.workbook.sheets.map { ($0.id, $0.name) })
            if current != edit.sheetNames {
                let rewrite = edit.sheetRewriter(to: current)
                change.rewriteSurroundingText(rewrite)
                edit.originalText = rewrite(edit.originalText)
                edit.sheetNames = current
            }
            edit.referenceRevision = session.revision
        }
        edit.text = change.text
        edit.picked = CellEditing.Pick(sheetID: session.sheet.id, selection: selection, insertion: change)
        session.editing = edit
        display(change.text, selection: change.caret, in: input.field)
        editingChanged()
        return true
    }

    private func display(_ text: String, selection: NSRange, in field: NSTextField) {
        field.stringValue = text
        if field.currentEditor() == nil { window?.makeFirstResponder(field) }
        guard let native = field.currentEditor() as? NSTextView else { return }
        if native.string != text { native.string = text }
        native.setSelectedRange(selection)
        native.scrollRangeToVisible(selection)
    }

    private var cycledReference: FormulaReferenceEdit? {
        guard let input = formulaInput else { return nil }
        return FormulaReferenceEdit.cyclingAnchors(in: input.text, selection: input.selection)
    }

    var canCycleReference: Bool { cycledReference != nil }

    func cycleFormulaReference() {
        guard let input = formulaInput, let change = cycledReference, var edit = activeDraft(for: input.field) else { return }
        let last = edit.picked
        edit.text = change.text
        if let last, last.insertion.span.location == change.span.location {
            edit.picked = CellEditing.Pick(sheetID: last.sheetID, selection: last.selection, insertion: change)
        }
        session.editing = edit
        display(change.text, selection: change.caret, in: input.field)
        editingChanged()
    }

    func handleReferenceArrow(_ command: Selector) -> Bool {
        let step: (rows: Int, columns: Int, extend: Bool)
        switch command {
        case #selector(moveUp(_:)): step = (-1, 0, false)
        case #selector(moveDown(_:)): step = (1, 0, false)
        case #selector(moveLeft(_:)): step = (0, -1, false)
        case #selector(moveRight(_:)): step = (0, 1, false)
        case #selector(moveUpAndModifySelection(_:)): step = (-1, 0, true)
        case #selector(moveDownAndModifySelection(_:)): step = (1, 0, true)
        case #selector(moveLeftAndModifySelection(_:)): step = (0, -1, true)
        case #selector(moveRightAndModifySelection(_:)): step = (0, 1, true)
        default: return false
        }
        let from = currentPick?.selection.cursor ?? session.selection.cursor
        let next = session.adjacent(to: from, rows: step.rows, columns: step.columns)
        guard pickCellReference(next, extend: step.extend) else { return false }
        if canvas?.includeCursor(next) == true { needsLayout = true; layoutSubtreeIfNeeded() }
        scrollToCell(next)
        return true
    }
}
