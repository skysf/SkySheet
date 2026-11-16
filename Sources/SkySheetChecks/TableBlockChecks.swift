import Foundation
import SkySheetCore

/// 认表格块（设计 9.7 节）：规则和 main 一样，只改了一处：末行的公式只算这一行自己（横向逐行求和、常量求和）时，
/// 它是一条记录，不是合计。其余版式的固定期望（就是 main 的输出）见 TableLayoutChecks。
@MainActor
func tableBlockRegressionChecks() {
    rowLocalSumChecks()
    textRecordChecks()
    tableLayoutChecks()
}

/// 全是文字的记录：缺格、横向合并都不让第一条记录变成第二行表头（前几轮的规则吞过 Alice；main 本来就对）。
@MainActor
func textRecordChecks() {
    group("table blocks: text records stay records") {
        let record = ["A1": "Name", "C1": "Color", "A2": "Alice", "B2": "East", "C2": "Blue", "A3": "Bob", "B3": "West", "C3": "Red"]
        for (name, cells, merges, rows) in [
            ("two text columns", ["A1": "Name", "B1": "Color", "A2": "Alice", "B2": "Blue", "A3": "Bob", "B3": "Red"], [String](), 1...2),
            ("sparse", record, [], 1...2),
            ("merged", record, ["A1:B1"], 1...2),
            ("merged gap", ["A1": "Name", "C1": "Color", "A2": "Alice", "C2": "Blue", "A3": "Bob", "C3": "Red"], ["A1:B1"], 1...2),
            ("merged, number only in a later row", record.merging(["A4": "Count", "C4": "=COUNTA(C2:C3)"]) { $1 }, ["A1:B1"], 1...3),
        ] {
            var workbook = Workbook(sheets: [makeSheet("S", id: 1, cells)])
            workbook.sheets[0].merges = merges.map { CellRange(a1: $0)! }
            Recalculator.recalculate(&workbook)
            let block = TableBlocks.find(in: workbook.sheets[0])[0]
            checkEqual(block.headerRow, 0, "\(name): single header row")
            checkEqual(block.dataRows, rows, "\(name): Alice stays a record")
            checkEqual(block.columns.map(\.name), name == "two text columns" ? ["Name", "Color"] : ["Name", "B", "Color"],
                       "\(name): column names from the header")
            let result = try SQLQuery.run("SELECT count(*), min(Name) FROM S", tables: QueryTables.tables(for: workbook))
            checkEqual(result.rows[0], [.integer(Int64(rows.count)), .text("Alice")], "\(name): SQL keeps Alice")
        }
    }
}

/// PR #12 最初的问题：main 只要末行有 SUM 就当合计删掉，横向逐行求和、常量求和的最后一条记录会从
/// describe_sheet 和 SQL 里静默消失。
@MainActor
func rowLocalSumChecks() {
    let records = ["A1": "Name", "B1": "Jan", "C1": "Feb", "D1": "Total",
                   "A2": "Alice", "B2": "1", "C2": "2", "D2": "=SUM(B2:C2)", "A3": "Bob", "B3": "3", "C3": "4", "D3": "=SUM(B3:C3)"]
    func block(_ cells: [String: String]) -> (Workbook, TableBlock) {
        var workbook = Workbook(sheets: [makeSheet("S", id: 1, cells), makeSheet("Other", id: 2, ["B4": "20", "C4": "30"])])
        Recalculator.recalculate(&workbook)
        return (workbook, TableBlocks.find(in: workbook.sheets[0])[0])
    }
    group("table blocks: row-local SUM rows are records") {
        // 横向求和：Bob 这一行的 SUM 只加自己（main 删了 Bob，Jan 的合计只剩 1）。
        let (horizontal, kept) = block(records)
        checkEqual(kept.totalsRow, nil, "horizontal SUM is not a total")
        checkEqual(kept.dataRows, 1...2, "Bob stays a record")
        let jan = ColumnSummary(column: 1, rows: kept.dataRows!, in: horizontal.sheets[0], styles: horizontal.styles,
                                dateSystem: horizontal.dateSystem)
        checkEqual(jan.count, 2, "describe_sheet counts Bob")
        checkEqual(jan.sum, 4, "describe_sheet Jan sum")
        let rows = try SQLQuery.run("SELECT count(*), sum(Jan), sum(Total), max(Name) FROM S", tables: QueryTables.tables(for: horizontal))
        checkEqual(rows.rows[0], [.integer(2), .real(4), .real(10), .text("Bob")], "SQL keeps Bob")

        // 常量求和：甲 =SUM(1,2)、乙 =SUM(3,4)，金额合计是 10（main 删了乙，只剩 3）。
        let (constant, both) = block(["A1": "项目", "B1": "金额", "A2": "甲", "B2": "=SUM(1,2)", "A3": "乙", "B3": "=SUM(3,4)"])
        checkEqual(both.totalsRow, nil, "constant SUM is not a total")
        let amount = ColumnSummary(column: 1, rows: both.dataRows!, in: constant.sheets[0], styles: constant.styles,
                                   dateSystem: constant.dateSystem)
        checkEqual(amount.sum, 10, "describe_sheet sum of the constant SUMs")
        let sum = try SQLQuery.run("SELECT count(*), sum(\"金额\") FROM S", tables: QueryTables.tables(for: constant))
        checkEqual(sum.rows[0], [.integer(2), .real(10)], "SQL sum of the constant SUMs")

        // 同一种写法的几个变体：SUBTOTAL、带本 sheet 名、再做算术、混着常量，引用都在本行。
        for formula in ["=SUBTOTAL(9,B4:C4)", "=SUM(S!B4:C4)", "=SUM(B4:C4)*2", "=SUM(B4,C4,1)"] {
            let (_, carol) = block(records.merging(["A4": "Carol", "B4": "5", "C4": "6", "D4": formula]) { $1 })
            checkEqual(carol.totalsRow, nil, "\(formula): not a total")
            checkEqual(carol.dataRows, 1...3, "\(formula): Carol stays a record")
        }
    }
    // 例外只有这一种，其余照 main：末行有公式引到别的行、别的 sheet，或者看不出引到哪儿（名称、OFFSET、
    // INDIRECT、切不了词），只要有以 SUM( / SUBTOTAL( 开头的公式就还是合计。
    group("table blocks: other SUM rows stay totals as in main") {
        for (label, row) in [
            // 竖向合计用加号写、合计列用横向 SUM：这一行引用了上面的行，是合计。
            ("plus totals", ["A4": "合计", "B4": "=B2+B3", "C4": "=C2+C3", "D4": "=SUM(B4:C4)"]),
            ("vertical SUM", ["A4": "合计", "B4": "=SUM(B2:B3)", "C4": "=SUM(C2:C3)", "D4": "=SUM(B4:C4)"]),
            ("reference above", ["A4": "Carol", "B4": "5", "C4": "6", "D4": "=SUM(B4:C4,B3)"]),
            ("other sheet", ["A4": "Carol", "B4": "5", "C4": "6", "D4": "=SUM(Other!B4:C4)"]),
            ("OFFSET", ["A4": "合计", "B4": "=SUM(OFFSET(A4,-2,1,2,1))"]),
            ("INDIRECT", ["A4": "合计", "B4": "=SUM(INDIRECT(\"B2:B3\"))"]),
            ("name", ["A4": "合计", "B4": "=SUM(Jan)"]),
            ("unparsed", ["A4": "合计", "B4": "=SUBTOTAL(9;B2:B3)"]),
        ] {
            checkEqual(block(records.merging(row) { $1 }).1.totalsRow, 3, "\(label): a total as in main")
        }
        // 结构化引用切不了词（文件里带着缓存值），照 main 当合计。
        var sheet = makeSheet("S", id: 1, records.merging(["A4": "Total"]) { $1 })
        sheet.cells[CellAddress(a1: "B4")!] = Cell(value: .number(4), formula: CellFormula(source: "SUBTOTAL(109,表1[Jan])", cachedValue: .number(4)))
        checkEqual(TableBlocks.find(in: sheet)[0].totalsRow, 3, "structured SUBTOTAL: a total as in main")
    }
}
