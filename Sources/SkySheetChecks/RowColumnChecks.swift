import Foundation
import SkySheetCore

/// 行和列（设计第 11、16 条，2026-10-14 加）：插删行列时格子、公式、名称、合并单元格、冻结窗格、行高列宽怎么跟着挪；
/// 列宽行高和隐藏怎么记；合并单元格；Format 菜单用到的几样新样式。
@MainActor
func rowColumnChecks() {
    group("rows and columns: where a line goes") {
        let insert = LineShift.insert(2, at: 4, .rows)
        checkEqual(insert.map(3), 3, "above the insertion stays")
        checkEqual(insert.map(4), 6, "the insertion row moves down")
        checkEqual(insert.map(2...6), 2...8, "a span across it grows")
        checkEqual(insert.map(4...6), 6...8, "a span starting there moves")
        checkEqual(insert.map(0...3), 0...3, "a span ending just above stays")
        checkEqual(insert.map(CellAddress.maxRows - 1), nil, "pushed off the sheet")
        checkEqual(insert.map(0...(CellAddress.maxRows - 1)), 0...(CellAddress.maxRows - 1), "a whole-sheet span is cut at the edge")
        let delete = LineShift.delete(4...6, .rows)
        checkEqual(delete.map(5), nil, "a deleted row is gone")
        checkEqual(delete.map(7), 4, "below moves up")
        checkEqual(delete.map(2...9), 2...6, "a span across it shrinks")
        checkEqual(delete.map(5...9), 4...6, "a span starting inside keeps the rest")
        checkEqual(delete.map(1...5), 1...3, "a span ending inside keeps the rest")
        checkEqual(delete.map(4...6), nil, "a span that is all deleted is gone")
        checkEqual(LineShift.delete(0...0, .columns).map(CellRange(a1: "A1:C3")!), CellRange(a1: "A1:B3"), "ranges shift along one axis")
    }

    group("rows and columns: formula references follow") {
        func rows(_ formula: String, _ shift: LineShift, local: Bool = true) -> String? {
            FormulaRewriter.shiftLines(in: formula, sheet: "Plan", local: local, shift)
        }
        let insert = LineShift.insert(2, at: 2, .rows)   // 在第 3 行前面插两行
        checkEqual(rows("A5+$B$5+A1", insert), "A7+$B$7+A1", "relative and absolute both move; rows above stay")
        checkEqual(rows("SUM(A1:A10)", insert), "SUM(A1:A12)", "the range grows")
        checkEqual(rows("sum(a1)+a1:a2", insert), "sum(a1)+a1:a2", "untouched references keep their spelling")
        checkEqual(rows("SUM(A1:A2)", insert), "SUM(A1:A2)", "a range ending just above stays as it was")
        checkEqual(rows("SUM(A3:A4)", insert), "SUM(A5:A6)", "a range starting at the insertion moves")
        checkEqual(rows("SUM(A:A)+SUM(3:5)", insert), "SUM(A:A)+SUM(5:7)", "whole columns stay; whole rows move")
        checkEqual(rows("B9:A1", insert), "B11:A1", "a range written backwards keeps its order")
        checkEqual(rows("Plan!A5+'plan'!B5+Loan!A5", insert, local: false), "Plan!A7+'plan'!B7+Loan!A5",
                   "from another sheet only references to this sheet move, quoted or not")
        checkEqual(rows("A5", insert, local: false), "A5", "unqualified references on another sheet are not ours")
        checkEqual(rows("\"A5\"&A5", insert), "\"A5\"&A7", "text that looks like a reference is left alone")
        checkEqual(rows("A1048576", .insert(1, at: 0, .rows)), "#REF!", "pushed off the sheet")

        let delete = LineShift.delete(2...3, .rows)   // 删掉第 3、4 行
        checkEqual(rows("A3*2", delete), "#REF!*2", "a deleted cell is #REF!")
        checkEqual(rows("Plan!A3+1", delete, local: false), "Plan!#REF!+1", "with the sheet name kept, like Excel")
        checkEqual(rows("SUM(A1:A10)", delete), "SUM(A1:A8)", "the range shrinks")
        checkEqual(rows("SUM(A3:A4)", delete), "SUM(#REF!)", "a range that is all deleted")
        checkEqual(rows("SUM(A4:A6)", delete), "SUM(A3:A4)", "a range starting inside keeps the rest")
        checkEqual(rows("A5", delete), "A3", "below moves up")

        func columns(_ formula: String, _ shift: LineShift) -> String? {
            FormulaRewriter.shiftLines(in: formula, sheet: "Plan", local: true, shift)
        }
        checkEqual(columns("B1+A1", .insert(1, at: 1, .columns)), "C1+A1", "inserting a column")
        checkEqual(columns("SUM(A:C)+SUM(1:1)", .insert(1, at: 1, .columns)), "SUM(A:D)+SUM(1:1)", "whole columns grow, rows stay")
        checkEqual(columns("D1-C1", .delete(2...2, .columns)), "C1-#REF!", "deleting a column")
        checkEqual(rows("SUM(Table1[Amount])", insert), nil, "formulas SkySheet can't read are reported, not skipped")
    }

    group("rows and columns: inserting rows in a workbook") {
        var workbook = Workbook(sheets: [
            makeSheet("Plan", id: 1, ["A1": "1", "A2": "2", "A3": "3", "A4": "=SUM(A1:A3)", "B4": "=A3*2"]),
            makeSheet("Other", id: 2, ["A1": "=Plan!A3+Plan!A1", "A2": "=A3"]),
        ])
        workbook.definedNames = [DefinedName(name: "Totals", formula: "Plan!$A$4"), DefinedName(name: "Top", formula: "Plan!$A$1")]
        workbook.sheets[0].merges = [CellRange(a1: "C2:D4")!, CellRange(a1: "C6:D6")!]
        workbook.sheets[0].frozen = FrozenPanes(rows: 2, columns: 1)
        workbook.sheets[0].rowFormats = [1: RowFormat(height: 30), 3: RowFormat(hidden: true)]
        workbook.sheets[0].cells[CellAddress(a1: "E2")!] = Cell(value: .text("rich"))
        workbook.sheets[0].richTextSources = [CellAddress(a1: "E2")!: 7]
        let report = try workbook.insert(2, .rows, at: 1, sheet: 0)   // 在第 2 行前面插两行
        Recalculator.recalculate(&workbook, options: RecalcOptions(today: checkToday))
        let plan = workbook.sheets[0]
        func cell(_ sheet: Int, _ a1: String) -> Cell? { workbook.sheets[sheet].cells[CellAddress(a1: a1)!] }
        checkEqual(cell(0, "A4")?.value, .number(2), "cells below moved down")
        checkEqual(cell(0, "A6")?.formula?.source, "SUM(A1:A5)", "the sum grows over the new rows")
        checkEqual(cell(0, "A6")?.value, .number(6), "and still adds up")
        checkEqual(cell(0, "B6")?.formula?.source, "A5*2", "same-sheet references move")
        checkEqual(cell(1, "A1")?.formula?.source, "Plan!A5+Plan!A1", "other sheets follow")
        checkEqual(cell(1, "A2")?.formula?.source, "A3", "their own references don't")
        checkEqual(workbook.definedNames.map(\.formula), ["Plan!$A$6", "Plan!$A$1"], "defined names follow")
        checkEqual(plan.merges, [CellRange(a1: "C4:D6")!, CellRange(a1: "C8:D8")!], "merges move")
        checkEqual(plan.frozen, FrozenPanes(rows: 4, columns: 1), "inserting inside the frozen rows freezes them too")
        checkEqual(plan.rowFormats[3]?.height, 30, "row heights move")
        checkEqual(plan.rowFormats[5]?.hidden, true, "hidden rows stay hidden")
        checkEqual(plan.rowFormats[1], nil, "the new rows copy the row above (row 1 had nothing)")
        checkEqual(plan.richTextSources, [CellAddress(a1: "E4")!: 7], "rich text stays with its cell")
        checkEqual(report.updatedFormulas, 3, "three formulas changed")
        check(report.brokenFormulas.isEmpty, "nothing broken by an insert")
    }

    group("rows and columns: deleting rows and columns in a workbook") {
        var workbook = Workbook(sheets: [
            makeSheet("Plan", id: 1, ["A1": "1", "A2": "2", "A3": "3", "A4": "=SUM(A1:A3)", "B4": "=A2", "C1": "x"]),
            makeSheet("Other", id: 2, ["A1": "=Plan!A2", "A2": "=SUM(Plan!A1:A3)"]),
        ])
        workbook.sheets[0].merges = [CellRange(a1: "C1:C3")!, CellRange(a1: "D2:E2")!]
        workbook.sheets[0].frozen = FrozenPanes(rows: 3, columns: 0)
        let report = try workbook.delete(1...1, .rows, sheet: 0)   // 删掉第 2 行
        Recalculator.recalculate(&workbook, options: RecalcOptions(today: checkToday))
        func cell(_ sheet: Int, _ a1: String) -> Cell? { workbook.sheets[sheet].cells[CellAddress(a1: a1)!] }
        checkEqual(cell(0, "A2")?.value, .number(3), "the row below moved up")
        checkEqual(cell(0, "A3")?.formula?.source, "SUM(A1:A2)", "the sum shrinks")
        checkEqual(cell(0, "A3")?.value, .number(4), "and adds what is left")
        checkEqual(cell(0, "B3")?.formula?.source, "#REF!", "a reference to the deleted row")
        checkEqual(cell(0, "B3")?.value, .error(.ref), "shows #REF!")
        checkEqual(cell(1, "A1")?.formula?.source, "Plan!#REF!", "from another sheet too")
        checkEqual(cell(1, "A2")?.formula?.source, "SUM(Plan!A1:A2)", "ranges on other sheets shrink")
        checkEqual(workbook.sheets[0].merges, [CellRange(a1: "C1:C2")!], "merges shrink; a merge left with one cell is gone")
        checkEqual(workbook.sheets[0].frozen, FrozenPanes(rows: 2, columns: 0), "frozen rows shrink")
        checkEqual(report.brokenFormulas.map(\.address.a1).sorted(), ["A1", "B3"], "the formulas that now show #REF!")

        try workbook.delete(0...0, .columns, sheet: 0)   // 删掉 A 列
        checkEqual(cell(0, "B1")?.value, .text("x"), "columns move left")
        checkEqual(cell(0, "A3")?.formula?.source, "#REF!", "column B is now A")
        checkEqual(cell(1, "A2")?.formula?.source, "SUM(Plan!#REF!)", "a range all in the deleted column")
        checkEqual(workbook.sheets[0].merges, [CellRange(a1: "B1:B2")!], "merges move left")
    }

    group("rows and columns: inserting copies the format of the row above") {
        var sheet = makeSheet("Plan", id: 1, ["A1": "head", "A2": "1"])
        sheet.cells[1, 0]?.styleIndex = 3
        sheet.cells[1, 2] = Cell(styleIndex: 4)
        sheet.rowFormats = [1: RowFormat(height: 24, hidden: true, styleIndex: 2)]
        sheet.columns = [ColumnFormat(first: 1, last: 1, width: 20, styleIndex: 5), ColumnFormat(first: 3, last: 5, width: 9)]
        var workbook = Workbook(sheets: [sheet])
        try workbook.insert(2, .rows, at: 2, sheet: 0)
        let cells = workbook.sheets[0].cells
        checkEqual(cells[2, 0], Cell(styleIndex: 3), "new rows get the row above's styles, without its values")
        checkEqual(cells[3, 2], Cell(styleIndex: 4), "every styled cell of it")
        checkEqual(workbook.sheets[0].rowFormats[3], RowFormat(height: 24, styleIndex: 2), "and its height, but not hidden")
        try workbook.insert(1, .columns, at: 2, sheet: 0)
        checkEqual(workbook.sheets[0].columns, [ColumnFormat(first: 1, last: 2, width: 20, styleIndex: 5),
                                                ColumnFormat(first: 4, last: 6, width: 9)],
                   "a new column copies the one on its left; the ones after move")
        try workbook.insert(1, .columns, at: 5, sheet: 0)
        checkEqual(workbook.sheets[0].columns.last, ColumnFormat(first: 4, last: 7, width: 9), "inserting inside a run widens it")
    }

    group("rows and columns: what insert and delete refuse") {
        var workbook = Workbook(sheets: [makeSheet("Plan", id: 1, ["A1": "1", "B2": "=SUM(Table1[x])"])])
        workbook.sheets[0].cells[CellAddress(a1: "E1")!] = Cell(formula: CellFormula(source: "A1:A2*2", arrayRange: CellRange(a1: "E1:E3")))
        @MainActor func refuses(_ change: (inout Workbook) throws -> Void, _ expected: StructureEditError, _ message: String) {
            var copy = workbook
            do {
                try change(&copy)
                fail("\(message): accepted")
            } catch let error as StructureEditError {
                checkEqual(error, expected, message)
                check(copy == workbook, "\(message): nothing changed")
            } catch {
                fail("\(message): \(error)")
            }
        }
        refuses({ try $0.insert(1, .rows, at: 0, sheet: 0) }, .unreadableFormula(sheet: "Plan", cell: CellAddress(a1: "B2")!),
                "a formula SkySheet can't read")
        workbook.sheets[0].cells[CellAddress(a1: "B2")!] = nil
        refuses({ try $0.insert(1, .rows, at: 1, sheet: 0) }, .splitsArrayFormula(CellRange(a1: "E1:E3")!),
                "inserting inside an array formula")
        refuses({ try $0.delete(1...5, .rows, sheet: 0) }, .splitsArrayFormula(CellRange(a1: "E1:E3")!),
                "deleting part of an array formula")
        workbook.sheets[0].cells[CellAddress(row: CellAddress.maxRows - 1, column: 0)] = Cell(value: .number(1))
        refuses({ try $0.insert(1, .rows, at: 5, sheet: 0) }, .wouldPushContentOffSheet, "data on the last row")
        try workbook.delete(0...3, .rows, sheet: 0)
        checkEqual(workbook.sheets[0].cells[CellAddress(a1: "E1")!], nil, "deleting the whole array formula is fine")
    }

    group("rows and columns: sizes and hiding") {
        var sheet = Sheet(id: 1, name: "S")
        sheet.columns = [ColumnFormat(first: 0, last: 5, width: 10, styleIndex: 3)]
        sheet.setHidden(true, .columns, 2...3)
        checkEqual(sheet.columns, [ColumnFormat(first: 0, last: 1, width: 10, styleIndex: 3),
                                   ColumnFormat(first: 2, last: 3, width: 10, hidden: true, styleIndex: 3),
                                   ColumnFormat(first: 4, last: 5, width: 10, styleIndex: 3)], "hiding splits the run, width kept")
        checkEqual(sheet.hiddenLines(.columns, in: 0...9), [2, 3], "hidden columns")
        check(sheet.isHidden(.columns, 3) && !sheet.isHidden(.columns, 4), "isHidden")
        sheet.setHidden(false, .columns, 0...9)
        checkEqual(sheet.columns, [ColumnFormat(first: 0, last: 5, width: 10, styleIndex: 3)], "unhiding joins the runs again")
        sheet.setColumnWidth(nil, columns: 0...5)
        checkEqual(sheet.columns, [ColumnFormat(first: 0, last: 5, styleIndex: 3)], "back to the default width, style kept")
        sheet.updateColumns(0...5) { $0.styleIndex = nil }
        checkEqual(sheet.columns, [], "a run with nothing left is dropped")
        sheet.setColumnWidth(12, columns: 0...(CellAddress.maxColumns - 1))
        checkEqual(sheet.columns, [ColumnFormat(first: 0, last: CellAddress.maxColumns - 1, width: 12)], "every column in one run")

        sheet.setRowHeight(30, rows: 2...4)
        sheet.setHidden(true, .rows, 3...3)
        checkEqual(sheet.rowFormats[3], RowFormat(height: 30, hidden: true), "a hidden row keeps its height")
        sheet.setRowHeight(nil, rows: 2...4)
        sheet.setHidden(false, .rows, 0...9)
        check(sheet.rowFormats.isEmpty, "rows back to default are not recorded")
        sheet.freeze(rows: 1, columns: 0)
        checkEqual(sheet.frozen, FrozenPanes(rows: 1, columns: 0), "freeze")
    }

    group("rows and columns: merging cells") {
        var workbook = Workbook(sheets: [makeSheet("S", id: 1, ["A1": "keep", "B1": "lose", "B2": ""])])
        workbook.sheets[0].cells[CellAddress(a1: "A1")!]?.styleIndex = 2
        workbook.sheets[0].merges = [CellRange(a1: "C1:C2")!, CellRange(a1: "D2:E2")!]
        checkEqual(workbook.cellsLostByMerging(CellRange(a1: "A1:B2")!, sheet: 0), [CellAddress(a1: "B1")!], "B1 would be lost")
        do {
            try workbook.merge(CellRange(a1: "A1:B2")!, sheet: 0)
            fail("merged over content")
        } catch let error as MergeError {
            checkEqual(error, .wouldDiscard([CellAddress(a1: "B1")!]), "refuses to lose content unless asked")
        }
        do {
            try workbook.merge(CellRange(a1: "C1:D2")!, sheet: 0)
            fail("merged across a merge")
        } catch let error as MergeError {
            checkEqual(error, .overlapsMerge(CellRange(a1: "D2:E2")!), "refuses to cut through a merge")
        }
        try workbook.merge(CellRange(a1: "A1:C2")!, sheet: 0, discardingOthers: true)
        let sheet = workbook.sheets[0]
        checkEqual(sheet.merges, [CellRange(a1: "D2:E2")!, CellRange(a1: "A1:C2")!], "merges inside are absorbed")
        checkEqual(sheet.cells[CellAddress(a1: "A1")!]?.value, .text("keep"), "the top-left value stays")
        checkEqual(sheet.cells[CellAddress(a1: "B1")!], Cell(styleIndex: 2), "the others take its style, without values")
        checkEqual(workbook.unmerge(CellRange(a1: "B2")!, sheet: 0), 1, "unmerge what the range touches")
        checkEqual(workbook.sheets[0].merges, [CellRange(a1: "D2:E2")!], "the other merge stays")
    }

    group("rows and columns: new cell styles") {
        var workbook = Workbook(sheets: [makeSheet("S", id: 1, ["A1": "1"])])
        let range = CellRange(a1: "A1")!
        workbook.restyle(range, sheet: 0, .init(italic: true, fontColor: .rgb("FFC00000"), fillColor: .rgb("FFFFF2CC"),
                                                horizontal: .center, vertical: .top, wrapText: true))
        var style = workbook.sheets[0].cells[CellAddress(a1: "A1")!]!.styleIndex
        var format = workbook.styles.cellFormats[style]
        checkEqual(workbook.styles.fonts[format.fontID].italic, true, "italic")
        checkEqual(format.horizontalAlignment, "center", "centered")
        checkEqual(format.verticalAlignment, "top", "top")
        checkEqual(format.wrapText, true, "wrap")
        workbook.restyle(range, sheet: 0, .init(fontColor: .automatic, fillColor: .automatic, horizontal: .general,
                                                vertical: .bottom, wrapText: false))
        style = workbook.sheets[0].cells[CellAddress(a1: "A1")!]!.styleIndex
        format = workbook.styles.cellFormats[style]
        checkEqual(workbook.styles.fonts[format.fontID].color, nil, "automatic text color")
        checkEqual(format.fillID, 0, "no fill is the file's own none fill")
        checkEqual([format.horizontalAlignment, format.verticalAlignment], [nil, nil], "defaults are not written")
        checkEqual(FormatPreset.general.code, "General", "general preset")
        workbook.restyle(range, sheet: 0, .init(numberFormat: FormatPreset.number.code))
        style = workbook.sheets[0].cells[CellAddress(a1: "A1")!]!.styleIndex
        checkEqual(workbook.styles.cellFormats[style].numberFormatID, 4, "#,##0.00 is builtin 4")
    }

    group("rows and columns: writing whole rows and columns") {
        checkEqual(CellRange.columnSpan(a1: "$c:A"), 0...2, "columns, backwards and with $")
        checkEqual(CellRange.rowSpan(a1: "5"), 4...4, "one row")
        checkEqual(CellRange.parse("B:D")?.label, "B:D", "whole columns")
        checkEqual(CellRange.parse("3:5")?.label, "3:5", "whole rows")
        checkEqual(CellRange.parse("B2:D9")?.label, "B2:D9", "a block")
        checkEqual(CellRange.parse("B2:D"), nil, "not a range")
    }
}
