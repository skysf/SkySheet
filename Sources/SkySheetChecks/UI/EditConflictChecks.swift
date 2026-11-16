import AppKit
import SkySheetCore

@MainActor
func editingRenameChecks() {
    group("ui-27: unchanged editing preserves AI reference rewrites") {
        let address = CellAddress(a1: "A1")!
        for origin in [CellEditing.Origin.editing, .formulaBar, .typing] {
            let session = renameSession()
            session.beginEditing(origin)
            try session.apply("AI rename", author: .ai(client: "Check", model: nil)) { try $0.renameSheet(1, to: "Renamed") }
            let beforeCommit = session.workbook
            let revision = session.revision
            session.commitEditing()
            checkEqual(session.workbook, beforeCommit, "unchanged editor cannot overwrite AI rewrite")
            checkEqual(session.revision, revision, "unchanged commit registers no extra edit")
            checkEqual(session.sheet.cells[address]?.formula?.source, "Renamed!A1", "reference keeps new sheet name")
            checkEqual(session.sheet.cells[address]?.value, .number(7), "unchanged reference still evaluates")
            session.commitEditing()
            checkEqual(session.revision, revision, "repeat commit stays a no-op")
        }
    }
    group("ui-27: user changes follow renamed sheet IDs and undo exactly") {
        let address = CellAddress(a1: "A1")!
        for changeBeforeRename in [true, false] {
            let session = renameSession()
            let undo = UndoManager()
            undo.groupsByEvent = false
            session.undoManager = undo
            session.beginEditing(.editing)
            if changeBeforeRename { session.editing?.text = "=Other!A1+1" }
            undo.beginUndoGrouping()
            try session.apply("AI rename", author: .ai(client: "Check", model: nil)) { try $0.renameSheet(1, to: "First") }
            try session.apply("AI rename", author: .ai(client: "Check", model: nil)) { try $0.renameSheet(1, to: "O'Brien Plan") }
            undo.endUndoGrouping()
            if !changeBeforeRename { session.editing?.text = "=Other!A1+1" }
            let before = session.workbook
            undo.beginUndoGrouping()
            session.commitEditing()
            undo.endUndoGrouping()
            checkEqual(session.sheet.cells[address]?.formula?.source, "'O''Brien Plan'!A1+1", "edited reference follows chained and quoted renames")
            checkEqual(session.sheet.cells[address]?.value, .number(8), "user change evaluates with the new sheet name")
            let after = session.workbook
            undo.undo()
            checkEqual(session.workbook, before, "undo preserves AI rename and removes only user typing")
            undo.redo()
            checkEqual(session.workbook, after, "redo restores translated input exactly")
        }
    }
    group("ui-27: swapping sheet names maps references once") {
        let session = renameSession()
        session.apply("Add AI sheet") { $0.sheets.append(Sheet(id: 3, name: "Third")) }
        session.beginEditing(.editing)
        session.editing?.text = "=other!A1+Third!A1"
        try session.apply("AI swap") {
            try $0.renameSheet(1, to: "Temporary")
            try $0.renameSheet(2, to: "Other")
            try $0.renameSheet(1, to: "Third")
        }
        session.commitEditing()
        checkEqual(session.sheet.cells[CellAddress(a1: "A1")!]?.formula?.source, "Third!A1+Other!A1", "stable IDs prevent cascading name replacements")
        checkEqual(session.sheet.cells[CellAddress(a1: "A1")!]?.value, .number(7), "both references retain their original sheets")
    }
}

@MainActor
private func renameSession() -> SheetSession {
    let address = CellAddress(a1: "A1")!
    var original = Sheet(id: 1, name: "Main")
    original.cells[address] = Cell(formula: CellFormula(source: "Other!A1"))
    let role = SheetRole.ai(AIAuthorship(created: .init(.ai(client: "Check", model: nil), date: Date(timeIntervalSince1970: 0))))
    var other = Sheet(id: 2, name: "Other", role: role)
    other.cells[address] = Cell(value: .number(7))
    return SheetSession(workbook: Workbook(sheets: [original, other]))
}
