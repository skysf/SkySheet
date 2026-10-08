import Foundation
import SkySheetCore

/// 公式的语法、运算规则、引用平移、重算（设计第五节）。
@MainActor
func formulaChecks() {
    group("formula: operators and precedence") {
        checkValue("1+2*3", num("7"))
        checkValue("-2^2", num("4"))               // 负号比乘方优先，和 Excel 一样
        checkValue("2^3^2", num("64"))             // 乘方左结合
        checkValue("(1+2)*3", num("9"))
        checkValue("10/4", num("2.5"))
        checkValue("5%", num("0.05"))
        checkValue("-5%", num("-0.05"))
        checkValue("0.1+0.2", num("0.3"))           // Decimal：没有 0.30000000000000004
        checkValue("0.1+0.2=0.3", .bool(true))
        checkValue("1/0", .error(.div0))
        checkValue("\"a\"&1&TRUE", .text("a1TRUE"))
        checkValue("\"合计\"&1/3", .text("合计0.333333333333333"))
        checkValue("\"10\"+1", num("11"))
        checkValue("\"abc\"+1", .error(.value))
        checkValue("\"1,234\"+1", .error(.value))   // 带逗号的文字不是数
        checkValue("TRUE+1", num("2"))
        checkValue("\"a\"=\"A\"", .bool(true))       // 文字比较不分大小写
        checkValue("1<\"a\"", .bool(true))           // 数字 < 文字
        checkValue("\"z\"<TRUE", .bool(true))        // 文字 < 逻辑值
        checkValue("A1=0", .bool(true))              // 空格子和数字比当 0
        checkValue("A1=\"\"", .bool(true))           // 和文字比当 ""
        checkValue("A1", num("0"))                   // =A1 引用空格子显示 0
        checkValue("#N/A+1", .error(.na))
        checkValue("1/0+#N/A", .error(.div0))        // 左边的错误优先
        checkValue("2^0.5", num("1.4142135623730951"))
        checkValue("0^0", .error(.num))
        checkValue("(-8)^(1/3)", .error(.num))
        checkValue("1.0025^360", .number(try! decimalPower("1.0025", 360)))
    }

    group("formula: references") {
        let cells = ["A1": "1", "A2": "2", "A3": "3", "B1": "10", "B2": "20", "B3": "30"]
        checkValue("SUM(A1:B3)", cells, num("66"))
        checkValue("SUM(A:A)", cells, num("6"))
        checkValue("SUM(1:1)", cells, num("11"))
        checkValue("$A$1+A$2+$A3", cells, num("6"))
        checkEqual(evaluate("A1:A3*2", cells, at: "C2"), num("4"), "implicit intersection picks the same row")
        checkEqual(evaluate("A1:A3*2", cells, at: "C9"), .error(.value), "no intersection")
        let other = ["Loan": ["B2": "50000"], "房贷 明细": ["A1": "7"]]
        checkEqual(evaluate("Loan!B2/10", otherSheets: other), num("5000"), "sheet reference")
        checkEqual(evaluate("loan!B2", otherSheets: other), num("50000"), "sheet names ignore case")
        checkEqual(evaluate("'房贷 明细'!A1*2", otherSheets: other), num("14"), "quoted sheet name")
    }

    group("formula: functions are case-insensitive and Excel prefixes are stripped") {
        checkValue("sum(1,2)", num("3"))
        checkValue("_xlfn.CONCAT(\"a\",\"b\")", .text("ab"))
        checkValue("_xlfn._xlws.SUM(1)", num("1"))
    }

    group("formula: what we cannot calculate keeps the cached value") {
        var sheet = makeSheet("Sheet1", id: 1, ["A1": "5"])
        let cases: [(String, String)] = [("NOSUCHFUNC(A1)", "function NOSUCHFUNC"), ("MyName*2", "defined names"),
                                         ("SUM({1,2})", "could not read"), ("Table1[Amount]", "could not read"),
                                         ("Missing!A1", "sheet Missing")]
        for (row, (formula, _)) in cases.enumerated() {
            sheet.cells[CellAddress(row: row, column: 1)] = Cell(
                formula: CellFormula(source: formula, cachedValue: .number(Decimal(row + 100))))
        }
        var workbook = Workbook(sheets: [sheet])
        let report = Recalculator.recalculate(&workbook, options: RecalcOptions(today: checkToday))
        for (row, (formula, reason)) in cases.enumerated() {
            let location = FormulaLocation(sheet: 0, address: CellAddress(row: row, column: 1))
            let cell = workbook.sheets[0].cells[location.address]
            checkEqual(cell?.value, .number(Decimal(row + 100)), "\(formula) shows the cached value")
            check(report.notRecalculated[location]?.contains(reason) == true,
                  "\(formula): reason \(report.notRecalculated[location] ?? "none") mentions \(reason)")
        }
    }

    group("formula: recalculation order, chains and cycles") {
        // 2,000 行的链：每一行引用上一行。递归求值会把栈撑爆，按排好的顺序算就没事（设计 5.5 节）。
        var cells = ["A1": "1"]
        for row in 2...2000 { cells["A\(row)"] = "=A\(row - 1)+1" }
        cells["B1"] = "=A2000*2"
        var workbook = Workbook(sheets: [makeSheet("Sheet1", id: 1, cells)])
        var report = Recalculator.recalculate(&workbook, options: RecalcOptions(today: checkToday))
        checkEqual(workbook.sheets[0].cells[CellAddress(a1: "B1")!]?.value, num("4000"), "long chain")
        checkEqual(report.calculated, 2000, "formulas calculated")

        // 跨 sheet 的依赖：Sheet1 用到 Data 里的公式。
        workbook = Workbook(sheets: [makeSheet("Sheet1", id: 1, ["A1": "=Data!B1*2"]),
                                     makeSheet("Data", id: 2, ["A1": "21", "B1": "=A1"])])
        Recalculator.recalculate(&workbook, options: RecalcOptions(today: checkToday))
        checkEqual(workbook.sheets[0].cells[CellAddress(a1: "A1")!]?.value, num("42"), "cross-sheet dependency")

        workbook = Workbook(sheets: [makeSheet("Sheet1", id: 1, ["A1": "=B1+1", "B1": "=A1+1", "C1": "=C1",
                                                                 "D1": "=A1*0", "E1": "5"])])
        report = Recalculator.recalculate(&workbook, options: RecalcOptions(today: checkToday))
        let circular = Set(["A1", "B1", "C1"].map { FormulaLocation(sheet: 0, address: CellAddress(a1: $0)!) })
        checkEqual(report.circular, circular, "cycle members")
        checkEqual(workbook.sheets[0].cells[CellAddress(a1: "A1")!]?.value, .error(.circular), "cycle value")
        checkEqual(workbook.sheets[0].cells[CellAddress(a1: "D1")!]?.value, .error(.circular), "depends on a cycle")
        checkEqual(workbook.sheets[0].cells[CellAddress(a1: "E1")!]?.value, num("5"), "plain values untouched")
    }

    group("formula: reference shift") {
        checkEqual(ReferenceShift.shift("B2*C2", rows: 1, columns: 0), "B3*C3", "relative row")
        checkEqual(ReferenceShift.shift("$B$2*C2", rows: 1, columns: 1), "$B$2*D3", "absolute stays")
        checkEqual(ReferenceShift.shift("B$2+$C3", rows: 2, columns: 2), "D$2+$C5", "mixed")
        checkEqual(ReferenceShift.shift("SUM(A1:A3)", rows: 0, columns: 1), "SUM(B1:B3)", "range")
        checkEqual(ReferenceShift.shift("SUM(A:A)", rows: 5, columns: 1), "SUM(B:B)", "whole column")
        checkEqual(ReferenceShift.shift("Loan!A1+'房贷 明细'!B2", rows: 1, columns: 0),
                   "Loan!A2+'房贷 明细'!B3", "sheet prefixes kept as written")
        checkEqual(ReferenceShift.shift("\"A1\"&A1", rows: 1, columns: 0), "\"A1\"&A2", "text untouched")
        checkEqual(ReferenceShift.shift("A1-1", rows: -1, columns: 0), "#REF!-1", "moved off the sheet")
        checkEqual(ReferenceShift.shift("RATE(C5, -F5, B5) * 12", rows: 1, columns: 0),
                   "RATE(C6, -F6, B6) * 12", "spacing kept")
        checkEqual(ReferenceShift.shift("LOG10(A1)", rows: 1, columns: 0), "LOG10(A2)", "function names are not references")
    }
}

private func decimalPower(_ base: String, _ exponent: Int) throws -> Decimal {
    var result = Decimal()
    var input = Decimal(string: base)!
    _ = NSDecimalPower(&result, &input, exponent, .plain)
    return result
}
