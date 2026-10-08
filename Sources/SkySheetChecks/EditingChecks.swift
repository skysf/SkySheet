import Foundation
import SkySheetCore

/// 编辑（设计第 16 条）：输入的文字变成什么、合并单元格、粘贴、sheet 改名 / 复制 / 删除时公式和名称跟着改。
@MainActor
func editingChecks() {
    group("editing: what typing turns into") {
        checkEqual(CellInput.parse(""), .clear, "empty clears")
        checkEqual(CellInput.parse("=A1+1"), .formula("A1+1"), "formula")
        checkEqual(CellInput.parse("="), .value(.text("=")), "a lone = is text")
        checkEqual(CellInput.parse("'00123"), .value(.text("00123")), "apostrophe forces text")
        checkEqual(CellInput.parse("00123"), .value(.text("00123")), "leading zeros stay text")
        checkEqual(CellInput.parse("6222021234567890123"), .value(.text("6222021234567890123")), "card numbers stay text")
        checkEqual(CellInput.parse("true"), .value(.bool(true)), "boolean")
        checkEqual(CellInput.parse("-5"), .number(-5, format: nil), "plain number keeps the cell's format")
        checkEqual(CellInput.parse("12%"), .number(Decimal(string: "0.12")!, format: .builtin(9)), "percent")
        checkEqual(CellInput.parse("4.35%"), .number(Decimal(string: "0.0435")!, format: .builtin(10)), "percent with decimals")
        checkEqual(CellInput.parse("1,234"), .number(1234, format: .builtin(3)), "thousands separator")
        checkEqual(CellInput.parse("1,234.5"), .number(Decimal(string: "1234.5")!, format: .builtin(4)), "grouped decimals")
        checkEqual(CellInput.parse("¥1,234.50"), .number(Decimal(string: "1234.5")!, format: .custom("\"¥\"#,##0.00")), "yuan")
        checkEqual(CellInput.parse("-¥12"), .number(-12, format: .custom("\"¥\"#,##0")), "negative yuan")
        checkEqual(CellInput.parse("1,23"), .value(.text("1,23")), "bad grouping stays text")
        checkEqual(CellInput.parse("2025/12/1"), .number(45992, format: .builtin(14)), "date")
        checkEqual(CellInput.parse("2025-12-01 12:00"), .number(Decimal(string: "45992.5")!, format: .builtin(22)), "date and time")
        checkEqual(CellInput.parse("2025/12/1", dateSystem: .from1904), .number(44530, format: .builtin(14)), "1904 dates")
        checkEqual(CellInput.parse("2025/2/30"), .value(.text("2025/2/30")), "impossible date stays text")
    }

    group("editing: entering, clearing, pasting") {
        var workbook = Workbook(sheets: [Sheet(id: 1, name: "Loan")])
        workbook.sheets[0].merges = [CellRange(a1: "A1:B2")!]
        func cell(_ a1: String) -> Cell? { workbook.sheets[0].cells[CellAddress(a1: a1)!] }
        func enter(_ text: String, _ a1: String) {
            workbook.enter(CellInput.parse(text), at: CellAddress(a1: a1)!, sheet: 0)
        }

        enter("title", "B2")
        checkEqual(cell("A1")?.value, .text("title"), "typing inside a merge lands in its top-left cell")
        check(cell("B2") == nil, "nothing stored in the rest of the merge")

        enter("12%", "C1")
        checkEqual(workbook.styles.formatCode(forStyle: cell("C1")?.styleIndex ?? 0), "0%", "percent format applied")
        let percentStyle = cell("C1")?.styleIndex
        enter("50%", "C2")
        checkEqual(cell("C2")?.styleIndex, percentStyle, "same format reuses the same style")
        enter("¥1,234.50", "D1")
        checkEqual(workbook.styles.formatCode(forStyle: cell("D1")?.styleIndex ?? 0), "\"¥\"#,##0.00", "custom yuan format")
        checkEqual(workbook.styles.customNumberFormats.keys.sorted(), [164], "custom formats start at 164")
        enter("¥8.00", "D2")
        checkEqual(workbook.styles.customNumberFormats.count, 1, "the yuan format is reused")
        enter("1,234", "C1")
        checkEqual(cell("C1")?.styleIndex, percentStyle, "a formatted cell keeps its format")
        checkEqual(cell("C1")?.value, .number(1234), "but takes the number")

        enter("", "C1")
        checkEqual(cell("C1")?.value, .empty, "clearing removes the value")
        checkEqual(cell("C1")?.styleIndex, percentStyle, "clearing keeps the style")
        enter("=C2*2", "E1")
        workbook.clearContents(CellRange(a1: "C1:E2")!, sheet: 0)
        check(cell("E1") == nil, "a cleared unstyled cell disappears")
        checkEqual(cell("C2")?.styleIndex, percentStyle, "clear keeps styles")

        workbook.paste([["1", "x"], ["=A5", "2025-12-01"]], at: CellAddress(a1: "A5")!, sheet: 0)
        checkEqual(cell("A5")?.value, .number(1), "pasted number")
        checkEqual(cell("B5")?.value, .text("x"), "pasted text")
        checkEqual(cell("A6")?.formula?.source, "A5", "pasted formula")
        checkEqual(cell("B6")?.value, .number(45992), "pasted date")
    }

    group("editing: renaming, duplicating and deleting sheets") {
        var workbook = Workbook(sheets: [
            makeSheet("Loan", id: 1, ["A1": "100"]),
            makeSheet("Plan", id: 2, ["A1": "=Loan!A1*2", "A2": "=\"Loan!A1\"&'loan'!A1+Plan!A1"]),
        ])
        workbook.definedNames = [DefinedName(name: "Amount", formula: "Loan!$A$1"),
                                 DefinedName(name: "Local", formula: "Plan!$A$1", sheetIndex: 1)]
        func formula(_ sheet: Int, _ a1: String) -> String? { workbook.sheets[sheet].cells[CellAddress(a1: a1)!]?.formula?.source }

        try workbook.renameSheet(0, to: "My Loan")
        checkEqual(formula(1, "A1"), "'My Loan'!A1*2", "references follow the new name, quoted")
        checkEqual(formula(1, "A2"), "\"Loan!A1\"&'My Loan'!A1+Plan!A1", "text and other sheets untouched")
        checkEqual(workbook.definedNames[0].formula, "'My Loan'!$A$1", "defined names follow too")
        do {
            try workbook.renameSheet(0, to: "plan")
            fail("duplicate name accepted")
        } catch let error as SheetEditError {
            checkEqual(error, .invalidName(.duplicate), "names are unique, ignoring case")
        }
        do {
            try workbook.renameSheet(0, to: "A:B")
            fail("colon accepted")
        } catch let error as SheetEditError {
            checkEqual(error, .invalidName(.invalidCharacter(":")), "invalid character")
        }
        try workbook.renameSheet(0, to: "MY LOAN")
        checkEqual(workbook.sheets[0].name, "MY LOAN", "changing only the case is fine")

        let copy = workbook.duplicateSheet(0)
        checkEqual(copy, 1, "the copy goes right after the original")
        checkEqual(workbook.sheets.map(\.name), ["MY LOAN", "MY LOAN (2)", "Plan"], "copy name")
        checkEqual(workbook.sheets[1].id, 3, "new sheet id")
        checkEqual(workbook.definedNames[1].sheetIndex, 2, "sheet-scoped names keep pointing at their sheet")

        try workbook.deleteSheet(0)
        checkEqual(formula(1, "A1"), "#REF!*2", "references to a deleted sheet become #REF!")
        checkEqual(workbook.definedNames[0].formula, "#REF!", "names too")
        checkEqual(workbook.definedNames[1].sheetIndex, 1, "scopes shift left")
        workbook.duplicateSheet(0)
        checkEqual(workbook.sheets[1].id, 4, "ids are never reused, even after a delete")

        try workbook.deleteSheet(2)
        workbook.sheets[1].visibility = .hidden
        do {
            try workbook.deleteSheet(0)
            fail("deleted the last visible sheet")
        } catch let error as SheetEditError {
            checkEqual(error, .lastVisibleSheet, "the last visible sheet stays")
        }
    }

    group("editing: sheet names and formula text") {
        checkEqual(SheetName.copyName(of: "Loan", among: ["Loan", "Loan (2)"]), "Loan (3)", "next free copy name")
        let long = String(repeating: "长", count: 31)
        checkEqual(SheetName.copyName(of: long, among: [long]), String(repeating: "长", count: 27) + " (2)", "long names shortened")
        checkEqual(SheetName.problem(with: "", among: []), .empty, "empty")
        checkEqual(SheetName.problem(with: long + "x", among: []), .tooLong, "too long")
        checkEqual(SheetName.problem(with: "'x", among: []), .apostropheAtEdge, "apostrophe at the edge")
        checkEqual(SheetName.problem(with: "history", among: []), .reserved, "reserved")
        check(SheetName.problem(with: "房贷 明细", among: ["Loan"]) == nil, "Chinese and spaces are fine")

        checkEqual(FormulaRewriter.quotedSheetName("Loan"), "Loan", "plain name")
        checkEqual(FormulaRewriter.quotedSheetName("房贷"), "房贷", "Chinese name")
        checkEqual(FormulaRewriter.quotedSheetName("My Loan"), "'My Loan'", "space needs quotes")
        checkEqual(FormulaRewriter.quotedSheetName("A1"), "'A1'", "looks like a cell")
        checkEqual(FormulaRewriter.quotedSheetName("2025"), "'2025'", "starts with a digit")
        checkEqual(FormulaRewriter.quotedSheetName("O'Brien"), "'O''Brien'", "apostrophes doubled")

        checkEqual(FormulaRewriter.storageForm("=CONCAT(A1,IFS(B1,1))"), "_xlfn.CONCAT(A1,_xlfn.IFS(B1,1))", "_xlfn. added")
        checkEqual(FormulaRewriter.storageForm("_xlfn.CONCAT(A1)"), "_xlfn.CONCAT(A1)", "not added twice")
        checkEqual(FormulaRewriter.storageForm("SUM(A1:A3)&\"IFS(\""), "SUM(A1:A3)&\"IFS(\"", "text left alone")
        checkEqual(FormulaRewriter.removeSheet(in: "SUM(Loan!A1:B2)+A1", named: "LOAN"), "SUM(#REF!)+A1", "ranges too")
    }
}
