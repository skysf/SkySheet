import Foundation
import SkySheetCore
import SkySheetFiles


@MainActor
func tableBlockRegressionChecks() {
    constantSumDataChecks()
    boundaryTotalsChecks()
    totalRowCompatibilityChecks()
    textDataRowsChecks()
}

@MainActor
func constantSumDataChecks() {
    group("tableblock: constantSumData") {
        for name in ["constantSumData", "horizontalSumData"] {
            var workbook: Workbook
            if name == "constantSumData" {
                workbook = Workbook(sheets: [makeSheet("S", id: 1, ["A1": "项目", "B1": "金额", "A2": "甲",
                    "B2": "=SUM(1,2)", "A3": "乙", "B3": "=SUM(3,4)"])])
            } else {
                workbook = Workbook(sheets: [makeSheet("S", id: 1, ["A1": "Name", "B1": "Jan", "C1": "Feb", "D1": "Total",
                    "A2": "Alice", "B2": "1", "C2": "2", "D2": "=SUM(B2:C2)",
                    "A3": "Bob", "B3": "3", "C3": "4", "D3": "=SUM(B3:C3)"])])
            }
            Recalculator.recalculate(&workbook)
            let block = TableBlocks.find(in: workbook.sheets[0])[0]
            checkEqual(block.dataRows, 1...2, "both rows are data")
            checkEqual(block.totalsRow, nil, "data SUM is not a total")
            let rows = block.dataRows!
            let summary = ColumnSummary(column: 1, rows: rows, in: workbook.sheets[0], styles: workbook.styles, dateSystem: workbook.dateSystem)
            checkEqual(summary.count, 2, "describe_sheet includes both rows")
            checkEqual(summary.sum, name == "constantSumData" ? Decimal(10) : Decimal(4), "describe_sheet sum")
            let result = try SQLQuery.run("SELECT count(*), sum(\"\(name == "constantSumData" ? "金额" : "Jan")\") FROM S",
                                          tables: QueryTables.tables(for: workbook))
            checkEqual(result.rows[0], [.integer(2), .real(name == "constantSumData" ? 10 : 4)], "SQL includes both rows")
        }
    }
}

@MainActor
func boundaryTotalsChecks() {
    group("tableblock: boundaryTotals") {
        let base = ["A1": "Name", "B1": "Amount", "A2": "Alice", "B2": "1", "A3": "Bob", "B3": "2"]
        for formula in ["=SUM(B2:B3)", "=SUBTOTAL(9,B2:B3)", "=SUBTOTAL(109,B2:B3)"] {
            var cells = base
            cells["B4"] = formula
            checkEqual(TableBlocks.find(in: makeSheet("S", id: 1, cells))[0].totalsRow, 3, "vertical sum is total")
        }
        for label in ["合计", "总计", "Total", " Grand Total "] {
            var cells = base
            cells["A4"] = label
            cells["B4"] = "3"
            checkEqual(TableBlocks.find(in: makeSheet("S", id: 1, cells))[0].totalsRow, 3, "explicit label is total")
        }
        for formula in ["=SUM(B2,3)", "=SUM(B3:B3)", "=SUM(C4:D4)", "=SUBTOTAL(1,B2:B3)", "=SUM(Other!B2:B3)"] {
            var cells = base
            cells["B4"] = formula
            checkEqual(TableBlocks.find(in: makeSheet("S", id: 1, cells))[0].totalsRow, nil, "uncertain total remains data")
        }
    }
}

/// SQL 与 describe_sheet 共用边界；两边同时断言，防止汇总被再次当成数据加一遍。
@MainActor
func totalRowCompatibilityChecks() {
    group("table blocks: Excel and WPS totals") {
        let base = ["A1": "项目", "B1": "金额", "A2": "甲", "B2": "100", "A3": "乙", "B3": "200", "A4": "丙", "B4": "300"]
        for label in ["汇总", "共计", "合计：", "合 计", "合　计", "合计金额", "总计", "小计", "Total", "Sum", "Subtotal", " Grand Total : "] {
            var cells = base
            cells["A5"] = label
            cells["B5"] = "=SUM(B1:B4)"
            try checkTableSummary(Workbook(sheets: [makeSheet("S", id: 1, cells)]), column: 1, count: 3, sum: 600, total: 4)
        }
        // 结构化引用不支持重算，仿照文件读入提供缓存值；即使没标签也能凭 SUBTOTAL 编号认出。
        for code in [9, 109] {
            for label in ["汇总", "item"] {
                var sheet = makeSheet("S", id: 1, base.merging(["A5": label]) { $1 })
                sheet.cells[4, 1] = Cell(value: .number(600), formula: CellFormula(source: "SUBTOTAL(\(code),表1[金额])", cachedValue: .number(600)))
                try checkTableSummary(Workbook(sheets: [sheet]), column: 1, count: 3, sum: 600, total: 4)
            }
        }
        for source in ["SUM(B1:B4)", "SUM(B2:B4)", "SUM(S!B1:B4)"] {
            try checkTableSummary(Workbook(sheets: [makeSheet("S", id: 1, base.merging(["B5": "=" + source]) { $1 })]),
                                  column: 1, count: 3, sum: 600, total: 4)
        }
        let twoHeaders = ["A1": "基本", "C1": "还款", "A2": "项目", "B2": "金额", "C2": "利率",
                          "A3": "甲", "B3": "100", "C3": "0.03", "A4": "乙", "B4": "200", "C4": "0.04",
                          "A5": "合计：", "B5": "=SUM(B3:B4)"]
        try checkTableSummary(Workbook(sheets: [makeSheet("S", id: 1, twoHeaders)]), column: 1, count: 2, sum: 300, total: 4)
        let numbered = ["A1": "序号", "B1": "项目", "C1": "金额", "A2": "1", "B2": "甲", "C2": "100",
                        "A3": "2", "B3": "乙", "C3": "200", "B4": "合计", "C4": "=SUM(C1:C3)"]
        try checkTableSummary(Workbook(sheets: [makeSheet("S", id: 1, numbered)]), column: 2, count: 2, sum: 300, total: 3)
    }
    group("table blocks: uncertain totals disclosed") {
        let base = ["A1": "项目", "B1": "金额", "A2": "甲", "B2": "1", "A3": "乙", "B3": "2"]
        for (formula, expected) in [("SUM(B3:B3)", 5), ("SUM(B2:B2)", 4), ("SUM(Other!B2:B3)", 12), ("SUM(B2,3)", 7), ("ROUND(SUM(B3:B3),2)", 5), ("SUM (B3:B3)+1", 6)] {
            var sheet = makeSheet("S", id: 1, base.merging(["B4": "=" + formula]) { $1 })
            if formula == "SUM (B3:B3)+1" {
                // 文件可带当前解析器不支持的排版；缓存仍参与统计，提示不能随重算丢掉。
                sheet.cells[3, 1] = Cell(value: .number(3), formula: CellFormula(source: formula, cachedValue: .number(3)))
            }
            let workbook = Workbook(sheets: [sheet, makeSheet("Other", id: 2, ["B2": "4", "B3": "5"])])
            try checkTableSummary(workbook, column: 1, count: 3, sum: expected, total: nil)
        }
    }
}

@MainActor
private func checkTableSummary(_ original: Workbook, column: Int, count: Int, sum: Int, total: Int?) throws {
    var workbook = original
    Recalculator.recalculate(&workbook)
    let sheet = workbook.sheets[0]
    let block = TableBlocks.find(in: sheet)[0]
    checkEqual(block.totalsRow, total, "totals row")
    let summary = ColumnSummary(column: column, rows: block.dataRows!, in: sheet, styles: workbook.styles, dateSystem: workbook.dateSystem)
    checkEqual(summary.count, count, "describe count")
    checkEqual(summary.sum, Decimal(sum), "describe sum")
    let result = try SQLQuery.run("SELECT count(*), sum(\"金额\") FROM S", tables: QueryTables.tables(for: workbook))
    checkEqual(result.rows[0], [.integer(Int64(count)), .real(Double(sum))], "SQL count and sum")
    if total == nil {
        checkEqual(block.suspectedTotalsRow, block.range.end.row, "uncertain total flagged")
        check(block.note?.contains("Row \(block.range.end.row + 1) looks like a totals row and was not excluded") == true, "English describe warning")
    } else {
        checkEqual(block.suspectedTotalsRow, nil, "confirmed total has no warning")
    }
}

@MainActor
func textDataRowsChecks() {
    group("table blocks: text records are data") {
        let sheet = makeSheet("S", id: 1, ["A1": "Name", "B1": "Color", "A2": "Alice", "B2": "Blue", "A3": "Bob", "B3": "Red"])
        let block = TableBlocks.find(in: sheet)[0]
        checkEqual(block.headerRow, 0, "only the first row is a header")
        checkEqual(block.dataRows, 1...2, "both text records remain data")
        let sparse = makeSheet("S", id: 1, ["A1": "Name", "C1": "Color", "A2": "Alice", "C2": "Blue", "A3": "Bob", "C3": "Red"])
        checkEqual(TableBlocks.find(in: sparse)[0].dataRows, 1...2, "missing header column alone does not prove a second header")
    }
}
