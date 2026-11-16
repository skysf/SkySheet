import Foundation
import SkySheetCore

/// 认表格块（设计 9.7 节）：规则就是 main 的，期望也全是 main 的输出；版式的固定期望见 TableLayoutChecks。
/// 规则以后要改，得先在这里改期望，不能悄悄变。
@MainActor
func tableBlockRegressionChecks() {
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
