import AppKit
import SkySheetCore
import SkySheetFiles

/// 用离屏窗口自己的文本框和鼠标处理入口，能查出点完引用后键盘跑到别处、光标跑到末尾这种问题。
@MainActor
func formulaReferenceChecks() {
    group("formula entry: clicks, native typing, calculation and xlsx round trip") {
        let a1 = CellAddress(a1: "A1")!, a2 = CellAddress(a1: "A2")!, b1 = CellAddress(a1: "B1")!
        var data = Sheet(id: 1, name: "Data")
        data.cells[a1] = Cell(value: .number(50))
        data.cells[a2] = Cell(value: .number(30))
        var other = Sheet(id: 2, name: "O'Brien 📊")
        other.cells[a1] = Cell(value: .number(2))
        other.cells[a2] = Cell(value: .number(3))
        let session = SheetSession(workbook: Workbook(sheets: [data, other]))
        let controller = WorkbookViewController(session: session)
        let window = OffscreenWindow.make(controller, size: CGSize(width: 850, height: 460))
        OffscreenWindow.settle(window, for: 0.05)
        guard let grid = controller.spreadsheet, let bar = grid.formulaField else { return fail("editor not mounted") }

        @MainActor func click(_ cell: CellAddress, drag: Bool = false) {
            let rect = grid.viewRect(of: CellRange(cell))
            let location = grid.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
            let event = NSEvent.mouseEvent(with: drag ? .leftMouseDragged : .leftMouseDown, location: location,
                                          modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                          context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            if drag { grid.mouseDragged(with: event) } else { grid.mouseDown(with: event) }
        }
        @MainActor func type(_ text: String) {
            guard let native = window.firstResponder as? NSTextView else { return fail("lost text focus before \(text)") }
            native.insertText(text, replacementRange: native.selectedRange())
        }
        @MainActor func command(_ selector: Selector) {
            guard let native = window.firstResponder as? NSTextView else { return fail("lost focus before \(selector)") }
            native.doCommand(by: selector)
        }
        click(b1)
        let equals = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: "=",
                                      charactersIgnoringModifiers: "=", isARepeat: false, keyCode: 24)!
        grid.keyDown(with: equals)
        click(a1)
        checkEqual(session.editing?.text, "=A1", "first click inserts an address")
        type("+")
        click(a2)
        checkEqual(session.editing?.text, "=A1+A2", "second operand")
        checkEqual(session.revision, 0, "clicks only edit the draft")
        command(#selector(NSResponder.insertNewline(_:)))
        checkEqual(session.sheet.cells[b1]?.value, .number(80), "Return computes 50 + 30")
        click(b1)
        OffscreenWindow.settle(window, for: 0.03)
        checkEqual(bar.stringValue, "=A1+A2", "reselecting shows the actual formula")
        session.apply("Change source") { $0.enter(.value(.number(40)), at: a2, sheet: 0) }
        checkEqual(session.sheet.cells[b1]?.value, .number(90), "source changes recalculate")

        grid.beginEditing(.typing, text: "=(")
        click(a1); type("+"); click(a2); type(")*("); click(a1); type("-"); click(a2); type(")/"); click(a1)
        command(#selector(NSResponder.insertNewline(_:)))
        checkEqual(session.sheet.cells[b1]?.formula?.source, "(A1+A2)*(A1-A2)/A1", "mixed operators")
        checkEqual(session.sheet.cells[b1]?.value, .number(18), "precedence")

        click(b1)
        window.makeFirstResponder(bar)
        (bar.currentEditor() as? NSTextView)?.selectAll(nil)
        type("=SUM(")
        click(a2); click(a1, drag: true)
        checkEqual(session.editing?.text, "=SUM(A1:A2", "drag replaces the first endpoint")
        controller.cycleFormulaReference(nil)
        checkEqual(session.editing?.text, "=SUM($A$1:$A$2", "F4 anchors the picked range")
        type(")+")
        grid.selectSheetTab(1)
        OffscreenWindow.settle(window, for: 0.03)
        click(a1)
        checkEqual(session.editing?.text, "=SUM($A$1:$A$2)+'O''Brien 📊'!A1", "qualified foreign cell")
        type("*"); click(a2)
        command(#selector(NSResponder.insertNewline(_:)))
        checkEqual(session.sheetIndex, 0, "Return goes back to the result sheet")
        checkEqual(session.selection.cursor.a1, "B2", "Return moves from the result cell")
        checkEqual(session.sheet.cells[b1]?.value, .number(96), "range plus foreign cells")
        let bytes = try XLSXWriter.write(session.workbook, source: nil, baseline: nil).data
        let reopened = try XLSXReader.read(bytes)
        checkEqual(reopened.sheets[0].cells[b1]?.formula?.source, "SUM($A$1:$A$2)+'O''Brien 📊'!A1*'O''Brien 📊'!A2", "xlsx formula")
        checkEqual(reopened.sheets[0].cells[b1]?.value, .number(96), "xlsx cached result")

        click(b1)
        grid.beginEditing(.editing, text: "=SUM(A1)+2")
        (grid.editor.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: 5, length: 2))
        click(a2)
        checkEqual(session.editing?.text, "=SUM(A2)+2", "replace a selected reference inside an existing formula")
        grid.selectSheetTab(1)
        click(a1)
        command(#selector(NSResponder.cancelOperation(_:)))
        checkEqual(session.sheetIndex, 0, "Esc restores the formula sheet")
        checkEqual(session.selection.cursor, b1, "Esc restores the original selection")
        checkEqual(session.sheet.cells[b1]?.value, .number(96), "Esc discards every draft pick")

        grid.beginEditing(.typing, text: "plain")
        click(a1)
        checkEqual(session.sheet.cells[b1]?.value, .text("plain"), "plain text still commits on click")
        checkEqual(session.selection.cursor, a1, "plain text click selects its destination")
    }
    group("formula entry: insertion point and absolute references") {
        let cell = CellRange(a1: "C4")!
        func pick(_ draft: String) -> String? {
            FormulaReferenceEdit.picking(cell, sheet: nil, in: draft, selection: NSRange(location: draft.utf16.count, length: 0),
                                         previous: nil)?.text
        }
        for draft in ["=", "=-", "=2^", "=1&", "=IF(A1<>", "=IF(A1>=1,", "=ROUND(SUM(A:A)*", "=NEWFUNCTION(", "=SUM(A1:"] {
            checkEqual(pick(draft), draft + "C4", "operand slot in \(draft)")
        }
        for draft in ["text+", "'=A1+", "=\"text+", "=\"escaped\"\"+", "=33%", "=2+3", "=SUM(A1)"] {
            checkEqual(pick(draft), nil, "ordinary click after \(draft)")
        }
        var text = "=\"📊\"&'O''Brien'!C4"
        for label in ["$C$4", "C$4", "$C4", "C4"] {
            let change = FormulaReferenceEdit.cyclingAnchors(in: text, selection: NSRange(location: text.utf16.count, length: 0))
            text = change?.text ?? ""
            checkEqual(text, "=\"📊\"&'O''Brien'!" + label, "F4 cycles without touching the prefix")
        }
    }
}
