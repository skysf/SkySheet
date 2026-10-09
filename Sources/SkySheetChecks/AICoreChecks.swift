import Foundation
import SkySheetCore
import SkySheetFiles

/// AI 工具底下的核心零件（设计 9.2 节）：认表格块、SQL 查询、算公式不写、sheet 的增删挪、往下填充、改样式、列宽、署名。
@MainActor
func aiCoreChecks() {
    group("ai core: table blocks of the loan fixture") {
        var workbook = try XLSXReader.read(contentsOf: fixtureURL("loan.xlsx"))
        Recalculator.recalculate(&workbook, options: RecalcOptions(today: checkToday))
        let blocks = TableBlocks.find(in: workbook.sheets[0])
        checkEqual(blocks.map(\.name), ["Loan", "Loan_2"], "two blocks; single stray cells are not blocks")
        checkEqual(blocks[0].range.a1, "A1:R11", "first block spans the header row's notes too")
        checkEqual(blocks[0].headerRow, 0, "header row found even with a number among the headers")
        checkEqual(blocks[0].dataRows, 1...9, "data rows")
        checkEqual(blocks[0].totalsRow, 10, "the 合计 row with SUM formulas is the totals row")
        checkEqual(blocks[0].columns.prefix(3).map(\.name), ["贷款类型", "贷总额", "分期月份"], "column names from the header")
        checkEqual(blocks[1].title, "参考选项", "a lone text cell on top is the title")
        checkEqual(blocks[1].headerRow, nil, "rows of data with no header")
        checkEqual(blocks[1].columns.prefix(2).map(\.name), ["A", "B"], "no header: column letters")

        let amount = ColumnSummary(column: 1, rows: 1...9, in: workbook.sheets[0], styles: workbook.styles,
                                   dateSystem: workbook.dateSystem)
        checkEqual(amount.type, "number", "amount column is numbers")
        checkEqual(amount.count, 9, "count")
        checkEqual(amount.sum, Decimal(string: "937818.75"), "sum of the loans, exact")
        checkEqual(amount.maximum, 489000, "max")
        let kinds = ColumnSummary(column: 11, rows: 1...10, in: workbook.sheets[0], styles: workbook.styles,
                                  dateSystem: workbook.dateSystem)
        checkEqual(kinds.type, "text", "repayment type column is text")
        checkEqual(kinds.samples.count, 3, "three distinct samples")
    }

    group("ai core: SQL over table blocks") {
        var workbook = try XLSXReader.read(contentsOf: fixtureURL("loan.xlsx"))
        Recalculator.recalculate(&workbook, options: RecalcOptions(today: checkToday))
        let tables = QueryTables.tables(for: workbook)
        checkEqual(tables.map(\.name), ["Loan", "Loan_2"], "one table per block")
        let result = try SQLQuery.run("""
            SELECT _row, "贷款类型", "贷总额" FROM "Loan" WHERE "贷总额" > 100000 ORDER BY "贷总额" DESC
            """, tables: tables)
        checkEqual(result.columns, ["_row", "贷款类型", "贷总额"], "columns")
        checkEqual(result.rows.map { $0[1] }, [.text("商业贷款"), .text("公积金贷款")], "rows; the totals row is not a record")
        checkEqual(result.rows[0][0], .integer(3), "_row is the sheet row")
        checkEqual(result.rows[0][2], .real(489000), "numbers are numbers")
        let precise = try SQLQuery.run(#"SELECT "贷总额" FROM "Loan" WHERE _row = 10"#, tables: tables)
        checkEqual(precise.rows.first?.first, .real(8673.94), "amounts convert to the nearest double (no 8673.939999…)")
        let count = try SQLQuery.run(#"SELECT count(*) AS n, sum("C") FROM "Loan_2" WHERE "A" LIKE '%e%'"#, tables: tables)
        checkEqual(count.rows.first?.first, .integer(3), "title rows are not records; LIKE works")

        let extra = QueryTables.tables(for: workbook, extra: [("plans", 0, CellRange(a1: "A1:C4")!)])
        checkEqual(try SQLQuery.run(#"SELECT "分期月份" FROM plans"#, tables: extra).rows.count, 3, "a named range is a table")
        let limited = try SQLQuery.run(#"SELECT * FROM "Loan""#, tables: tables, limit: 4)
        check(limited.truncated && limited.rows.count == 4, "results are capped")

        @MainActor func rejects(_ sql: String, _ message: String, timeout: TimeInterval = 3) {
            do {
                _ = try SQLQuery.run(sql, tables: tables, timeout: timeout)
                fail("accepted: \(sql)")
            } catch {
                check(error.message.contains(message), "\(sql) → \(error.message)")
            }
        }
        rejects(#"DELETE FROM "Loan""#, "only SELECT")
        rejects(#"SELECT 1; DROP TABLE "Loan""#, "one statement")
        rejects("SELECT * FROM nowhere", "no such table")
        rejects("WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c",
                "longer than", timeout: 0.2)
    }

    group("ai core: evaluating a formula without writing it") {
        var workbook = try XLSXReader.read(contentsOf: fixtureURL("loan.xlsx"))
        Recalculator.recalculate(&workbook, options: RecalcOptions(today: checkToday))
        let before = workbook
        func value(_ formula: String) -> FormulaEvaluation.Outcome {
            FormulaEvaluation.evaluate(formula, in: workbook, sheet: 0, options: RecalcOptions(today: checkToday))
        }
        let rate = 0.031 / 12
        let payment = 1_000_000 * rate / (1 - pow(1 + rate, -360))
        guard case .value(let monthly) = value("=PMT(3.1%/12,360,-1000000)") else { fail("PMT failed"); return }
        checkNumber(monthly, payment, tolerance: 1e-12, "monthly payment")
        checkEqual(value("Loan!B2*2"), .value(.number(100_000)), "references read the workbook, = optional")
        checkEqual(value("=B3+1"), .value(.number(489_001)), "plain references use the given sheet")
        checkEqual(value("=F2"), .value(.number(Decimal(string: "922.57")!)), "formula cells give their computed value")
        guard case .unsupported(let reason) = value("=NOPE(1)") else { fail("unknown function accepted"); return }
        check(reason.contains("NOPE"), "unknown function explained")
        guard case .unsupported = value("=1+") else { fail("bad syntax accepted"); return }
        check(workbook == before, "nothing written")
    }

    group("ai core: adding, copying and moving sheets") {
        var workbook = Workbook(sheets: [makeSheet("Loan", id: 1, ["A1": "1", "B1": "=A1*2"])])
        workbook.definedNames = [DefinedName(name: "Local", formula: "Loan!$A$1", sheetIndex: 0)]
        do {
            try workbook.addSheet(named: "loan")
            fail("duplicate name accepted")
        } catch let error as SheetEditError {
            checkEqual(error, .invalidName(.duplicate), "names stay unique")
        }
        let ai = AIAuthorship(created: .init(.ai(client: "claude-code", model: "claude-opus-5-5"), date: Date(timeIntervalSince1970: 0)))
        let added = try workbook.addSheet(named: "Notes", at: 0, role: .ai(ai))
        checkEqual(added, 0, "inserted where asked")
        checkEqual(workbook.definedNames[0].sheetIndex, 1, "scoped names follow their sheet")
        checkEqual(workbook.sheets[0].role.authorship?.badge, "Claude", "badge from the model")
        let copy = try workbook.copySheet(1, named: "方案 A")
        checkEqual(workbook.sheets.map(\.name), ["Notes", "Loan", "方案 A"], "copy after the original")
        checkEqual(workbook.sheets[copy].cells[CellAddress(a1: "B1")!]?.formula?.source, "A1*2", "formulas copied")
        checkEqual(Set(workbook.sheets.map(\.id)).count, 3, "ids unique")
        workbook.moveSheet(from: 1, to: 2)
        checkEqual(workbook.sheets.map(\.name), ["Notes", "方案 A", "Loan"], "moved")
        checkEqual(workbook.definedNames[0].sheetIndex, 2, "scoped names move with the sheet")
    }

    group("ai core: fill down, styles, widths, freezing") {
        var workbook = Workbook(sheets: [makeSheet("Plan", id: 1, ["A1": "1", "A2": "2", "A3": "3", "B1": "=A1*2", "C1": "x"])])
        workbook.fillDown(row: 0, columns: 1...2, through: 2, sheet: 0)
        Recalculator.recalculate(&workbook, options: RecalcOptions(today: checkToday))
        let cells = workbook.sheets[0].cells
        checkEqual(cells[CellAddress(a1: "B3")!]?.formula?.source, "A3*2", "references shift down")
        checkEqual(cells[CellAddress(a1: "B3")!]?.value, .number(6), "and calculate")
        checkEqual(cells[CellAddress(a1: "C2")!]?.value, .text("x"), "values copied")

        let range = CellRange(a1: "A1:B2")!
        workbook.restyle(range, sheet: 0, Workbook.CellStyleChange(numberFormat: "0.00%", bold: true, fillColor: "FFFFF2CC"))
        let style = workbook.sheets[0].cells[CellAddress(a1: "A2")!]?.styleIndex ?? 0
        checkEqual(workbook.styles.formatCode(forStyle: style), "0.00%", "number format")
        checkEqual(workbook.styles.cellFormats[style].numberFormatID, 10, "a builtin id when the code is a standard one")
        checkEqual(workbook.styles.fonts[workbook.styles.cellFormats[style].fontID].bold, true, "bold")
        checkEqual(workbook.styles.fills[workbook.styles.cellFormats[style].fillID].foreground, StyleColor(.rgb("FFFFF2CC")), "fill")
        check(workbook.sheets[0].cells.entries(in: range).allSatisfy { $0.value.styleIndex == style }, "one style reused")
        let formats = workbook.styles.cellFormats.count
        workbook.restyle(range, sheet: 0, Workbook.CellStyleChange(numberFormat: "0.00%", bold: true, fillColor: "FFFFF2CC"))
        checkEqual(workbook.styles.cellFormats.count, formats, "styling again adds nothing")
        workbook.restyle(CellRange(a1: "D5")!, sheet: 0, Workbook.CellStyleChange(numberFormat: "\"¥\"#,##0.00"))
        check(workbook.sheets[0].cells[CellAddress(a1: "D5")!] != nil, "empty cells get the style too")
        checkEqual(workbook.styles.customNumberFormats.values.contains("\"¥\"#,##0.00"), true, "custom code added")

        workbook.sheets[0].columns = [ColumnFormat(first: 0, last: 5, width: 10, hidden: false, styleIndex: 3)]
        workbook.setColumnWidth(20, columns: 2...3, sheet: 0)
        checkEqual(workbook.sheets[0].columns, [
            ColumnFormat(first: 0, last: 1, width: 10, styleIndex: 3), ColumnFormat(first: 2, last: 3, width: 20, styleIndex: 3),
            ColumnFormat(first: 4, last: 5, width: 10, styleIndex: 3),
        ], "existing ranges split, styles kept, neighbours merged")
        workbook.freeze(rows: 1, columns: 0, sheet: 0)
        checkEqual(workbook.sheets[0].frozen, FrozenPanes(rows: 1, columns: 0), "freeze")
        workbook.freeze(rows: 0, columns: 0, sheet: 0)
        checkEqual(workbook.sheets[0].frozen, nil, "unfreeze")
    }

    group("ai core: functions Claude reached for (ROW, RANK…)") {
        checkEqual(evaluate("ROW()", at: "C7"), .number(7), "ROW of the formula's own cell")
        checkEqual(evaluate("ROW(Sheet1!B5)"), .number(5), "ROW of a reference")
        checkEqual(evaluate("COLUMN(C1:E9)"), .number(3), "COLUMN takes the top-left")
        checkEqual(evaluate("ROWS(A1:A4)*COLUMNS(A1:C1)"), .number(12), "ROWS and COLUMNS")
        let rates = ["A1": "0.0375", "A2": "0.0328", "A3": "0.0279", "A4": "0.0328"]
        checkEqual(evaluate("RANK(A2,A1:A4)", rates), .number(2), "ties share a rank")
        checkEqual(evaluate("RANK(A3,A1:A4)", rates), .number(4), "after a tie the next rank skips")
        checkEqual(evaluate("RANK.EQ(A3,A1:A4,1)", rates), .number(1), "ascending order")
        checkEqual(evaluate("RANK(0.5,A1:A4)", rates), .error(.na), "a number not in the list is #N/A")
        checkEqual(FormulaRewriter.storageForm("RANK.EQ(A1,B:B)"), "_xlfn.RANK.EQ(A1,B:B)", "saved with the _xlfn. prefix")
    }

    group("ai core: who wrote a sheet") {
        let date = Date(timeIntervalSince1970: 0)
        checkEqual(AIAuthorship(created: .init(.ai(client: "claude-code", model: nil), date: date)).badge, "Claude Code",
                   "no model: client name")
        checkEqual(AIAuthorship(created: .init(.ai(client: "x", model: "deepseek-v4"), date: date)).badge, "DeepSeek", "brand")
        checkEqual(AIAuthorship(created: .init(.user, date: date)).badge, "You", "marked by the user")
    }
}
