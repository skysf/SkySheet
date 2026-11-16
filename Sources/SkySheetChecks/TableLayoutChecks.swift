import Foundation
import SkySheetCore

/// 生成的表格版式与固定期望：表头行、合计行、列名、某一列的 describe 统计和 SQL 统计。
/// 期望全是 main 的输出（2026-11-16 和审查者留下的 main 版式输出逐例核对过），包括 main 的已知限制：
/// 认不出两行表头、手填数字的合计行，末行横向求和、常量求和的记录会被当成合计删掉（设计 9.7 节）。
/// 认表头、认合计要改得另行设计、由作者拍板，改的时候先在这里改期望，不能悄悄变。
struct TableLayoutCase {
    var name: String
    var cells: [String: String]
    var column: Int
    var header: Int?
    /// SQL 记录数，也就是数据行数。
    var rows: Int
    var sum: Decimal
    var total: Int?
    /// SQL 列名。
    var names: [String]
    var merges: [String] = []
    var cached: (address: String, source: String, value: Decimal)? = nil
    var format: String? = nil
    /// describe 里这一列有值的格数；列里有空格时和 SQL 记录数不同，默认相同。
    var values: Int? = nil
    /// describe 里这一列的类型。
    var type = "number"
}

func tableLayoutCases() -> [TableLayoutCase] {
    var cases: [TableLayoutCase] = []
    // two-headers：首行「基本 / 还款」只是缺格（原来的输入）；two-headers-merged 再把它们各自合并成分组。
    // main 都只认第一行作表头：列名是 基本 / B / 还款 / D，「项目 / 地区 / 颜色 / 金额」那一行算一条记录，
    // 金额列因此是 mixed（文字不进和）。
    for layout in ["single", "sparse", "merged", "two-headers", "two-headers-merged", "numbered"] {
        for count in [2, 3, 5] {
            var cells: [String: String] = [:]
            let grouped = layout.hasPrefix("two-headers")
            let header = grouped ? 1 : 0
            let column = layout == "numbered" ? 2 : layout == "merged" ? 4 : 3
            let names = layout == "numbered" ? ["序号", "项目", "金额"]
                : layout == "merged" ? ["项目", "", "颜色", "地区", "金额"] : ["项目", "地区", "颜色", "金额"]
            if grouped { cells = ["A1": "基本", "C1": "还款"] }
            for (index, name) in names.enumerated() where !(layout == "sparse" && index == 1) && !name.isEmpty {
                cells[CellAddress(row: header, column: index).a1] = name
            }
            for index in 1...count {
                let row = header + index
                let fields = layout == "numbered" ? [String(index), "记录\(index)", String(index * 100)]
                    : layout == "merged" ? ["记录\(index)", "", "Blue", "East", String(index * 100)]
                    : ["记录\(index)", "East", "Blue", String(index * 100)]
                for (col, value) in fields.enumerated() where !value.isEmpty { cells[CellAddress(row: row, column: col).a1] = value }
            }
            let sum = count * (count + 1) / 2 * 100
            let bottom = header + count + 1
            let letter = CellAddress.columnName(column)
            let merges = layout == "merged" ? ["A1:B1"] : layout == "two-headers-merged" ? ["A1:B1", "C1:D1"] : []
            let columns = grouped ? ["基本", "B", "还款", "D"] : layout == "sparse" ? ["项目", "B", "颜色", "金额"]
                : layout == "merged" ? ["项目", "B", "颜色", "地区", "金额"] : names
            for kind in ["no-total", "sum-data", "sum-header", "literal-total"] {
                var input = cells
                if kind != "no-total" {
                    input[CellAddress(row: bottom, column: layout == "numbered" ? 1 : 0).a1] = "合计"
                    input[CellAddress(row: bottom, column: column).a1] = kind == "literal-total" ? String(sum)
                        : "=SUM(\(letter)\(kind == "sum-header" ? header + 1 : header + 2):\(letter)\(bottom))"
                }
                // 手填数字的合计行没有 SUM，main 认不出，算一条记录，金额翻倍。
                let literal = kind == "literal-total"
                cases.append(TableLayoutCase(name: "\(layout)-\(count)-\(kind)", cells: input, column: column, header: 0,
                    rows: count + (grouped ? 1 : 0) + (literal ? 1 : 0), sum: Decimal(literal ? sum * 2 : sum),
                    total: kind == "no-total" || literal ? nil : bottom, names: columns, merges: merges,
                    type: grouped ? "mixed" : "number"))
            }
        }
    }
    let base = ["A1": "项目", "B1": "金额", "A2": "甲", "B2": "100", "A3": "乙", "B3": "200", "A4": "丙", "B4": "300"]
    func append(_ name: String, _ extra: [String: String], rows: Int = 3, sum: Decimal = 600, total: Int? = 4,
                cached: (String, String, Decimal)? = nil, format: String? = nil) {
        cases.append(TableLayoutCase(name: name, cells: base.merging(extra) { $1 }, column: 1, header: 0,
            rows: rows, sum: sum, total: total, names: ["项目", "金额"], cached: cached, format: format))
    }
    // 末行有以 SUM( / SUBTOTAL( 开头的公式就是合计，不看标签，也不核对范围从哪儿起、加的是不是本列。
    for label in ["合计", "总计", "小计", "汇总", "共计", "合计：", "合 计", "合　计", "Total", "Subtotal", " Grand Total : ", "Sum", "合计金额"] {
        append("review-label-\(label)", ["A5": label, "B5": "=SUM(B1:B4)"])
    }
    for source in ["SUM(B2:B4)", "SUM($B$2:$B$4)", "SUM(B$2:B4)", "SUM(S!B2:B4)", "SUM(B1:B4)",
                   "SUBTOTAL(9,B2:B4)", "SUBTOTAL(109,B1:B4)", "SUBTOTAL(9;B2:B4)", "SUM(B2:B2,B3:B4)"] {
        append("review-formula-\(source)", ["B5": "=" + source])
    }
    // 常量求和、只引本行的求和也一样当合计删掉：main 的已知限制。
    for (source, value) in [("SUM(B3:B4)", 500), ("SUM(B2:B3)", 300), ("SUM(Other!B2:B4)", 90), ("SUM(1,2)", 3), ("SUM(C5:D5)", 0),
                            ("SUBTOTAL(1,B2:B4)", 200), ("SUM(B2,3)", 103), ("SUM(B2:B4,B2:B4)", 1200), ("SUM(B1:B3)", 300)] {
        append("review-retain-\(source)", ["B5": "=" + source],
               cached: source == "SUBTOTAL(1,B2:B4)" ? ("B5", source, Decimal(value)) : nil)
    }
    append("review-before-header", ["B5": "=SUM(B1:B4)"])
    // 两行表头配合计（原来的输入，没有合并格）：main 只认第一行，「项目 / 金额 / 利率」算一条记录，合计行照样剔除。
    cases.append(TableLayoutCase(name: "two-row-header-total", cells: ["A1": "基本", "C1": "还款", "A2": "项目", "B2": "金额",
        "C2": "利率", "A3": "甲", "B3": "100", "C3": "0.03", "A4": "乙", "B4": "200", "C4": "0.04", "A5": "合计：", "B5": "=SUM(B3:B4)"],
        column: 1, header: 0, rows: 3, sum: 300, total: 4, names: ["基本", "B", "还款"], type: "mixed"))
    cases.append(TableLayoutCase(name: "numbered-total-in-B", cells: ["A1": "序号", "B1": "项目", "C1": "金额", "A2": "1", "B2": "甲",
        "C2": "100", "A3": "2", "B3": "乙", "C3": "200", "B4": "合计", "C4": "=SUM(C1:C3)"],
        column: 2, header: 0, rows: 2, sum: 300, total: 3, names: ["序号", "项目", "金额"]))
    // 结构化引用切不了词：照 main，公式以 SUBTOTAL( 开头就是合计，标签是 item 也一样。
    for code in [9, 109] {
        for label in ["汇总", "Total", "item"] {
            append("review-structured-\(code)-\(label)", ["A5": label], cached: ("B5", "SUBTOTAL(\(code),表1[金额])", 600))
        }
    }
    // 公式不以 SUM( 开头、手填的数字，main 都不当合计，算一条记录。
    append("review-round-sum", ["A5": "合计：", "B5": "=ROUND(SUM(B2:B4),2)"], rows: 4, sum: 1200, total: nil)
    append("precision-rounded-total", ["A5": "合计", "B5": "600.004"], rows: 4, sum: Decimal(string: "1200.004")!,
           total: nil, format: "0.00")
    append("precision-mismatch", ["A5": "合计", "B5": "600.006"], rows: 4, sum: Decimal(string: "1200.006")!,
           total: nil, format: "0.00")
    append("prefix-with-equal-sum", ["A5": "Summer", "B5": "600"], rows: 4, sum: 1200, total: nil)
    for label in ["合计", "总计", "小计", "汇总", "共计", "Total", "Subtotal", " Grand Total : ", "Sum", "合　计："] {
        append("exact-numeric-" + label, ["A5": label, "B5": "600"], rows: 4, sum: 1200, total: nil)
    }
    append("review-numeric-coincidence", [:], total: nil)
    for label in ["合计划款", "汇总表", "Summer", "Sumner", "Total Quality Management", "Summary account", "合计"] {
        for numbered in [false, true] {
            let cells = numbered ? ["A1": "序号", "B1": "项目", "C1": "金额", "A2": "1", "B2": "甲", "C2": "100", "A3": "2", "B3": label, "C3": "200"]
                : ["A1": "项目", "B1": "金额", "A2": "甲", "B2": "100", "A3": label, "B3": "200"]
            cases.append(TableLayoutCase(name: "review-ordinary-\(label)-\(numbered)", cells: cells, column: numbered ? 2 : 1,
                header: 0, rows: 2, sum: 300, total: nil, names: numbered ? ["序号", "项目", "金额"] : ["项目", "金额"]))
        }
    }
    cases.append(TableLayoutCase(name: "one-prior-record-is-insufficient", cells: ["A1":"项目", "B1":"金额", "A2":"甲", "B2":"100", "A3":"Total", "B3":"100"],
        column: 1, header: 0, rows: 2, sum: 200, total: nil, names: ["项目", "金额"]))
    // 只有一格的行是标题，不是表头。
    for header in [false, true] {
        cases.append(TableLayoutCase(name: "review-one-numeric-column-\(header)", cells: header
            ? ["A1": "金额", "A2": "100", "A3": "200", "A4": "300"] : ["A1": "100", "A2": "200", "A3": "300"],
            column: 0, header: nil, rows: 3, sum: 600, total: nil, names: ["A"]))
    }
    let small = ["A1":"项目", "B1":"金额", "A2":"甲", "B2":"1", "A3":"乙", "B3":"2"]
    for (source, value, total) in [("SUM(B3:B3)", 2, 3), ("SUM(B2:B2)", 1, 3), ("SUM(B2,3)", 4, 3),
                                   ("ROUND(SUM(B3:B3),2)", 2, nil), ("SUM (B3:B3)+1", 3, nil)] as [(String, Int, Int?)] {
        cases.append(TableLayoutCase(name: "review-small-" + source, cells: small.merging(["B4":"=" + source]) { $1 },
            column: 1, header: 0, rows: total == nil ? 3 : 2, sum: Decimal(total == nil ? 3 + value : 3), total: total,
            names: ["项目", "金额"], cached: source == "SUM (B3:B3)+1" ? ("B4", source, 3) : nil))
    }
    // main 的已知限制（排查最初发现的问题，以后单独设计）：横向逐行求和、常量求和的最后一条记录被当成合计删掉，
    // 乙只剩甲的 3，Bob 删掉后 Jan 只剩 1。
    cases.append(TableLayoutCase(name: "review-constant-row-sums", cells: ["A1":"项目", "B1":"金额", "A2":"甲", "B2":"=SUM(1,2)", "A3":"乙", "B3":"=SUM(3,4)"],
        column: 1, header: 0, rows: 1, sum: 3, total: 2, names: ["项目", "金额"]))
    cases.append(TableLayoutCase(name: "review-horizontal-row-sums", cells: ["A1":"Name", "B1":"Jan", "C1":"Feb", "D1":"Total", "A2":"Alice", "B2":"1", "C2":"2", "D2":"=SUM(B2:C2)", "A3":"Bob", "B3":"3", "C3":"4", "D3":"=SUM(B3:C3)"],
        column: 1, header: 0, rows: 1, sum: 1, total: 2, names: ["Name", "Jan", "Feb", "Total"]))
    // 范围从标题行开始的 SUM 照样是合计。
    let titled = ["A1":"Report", "A2":"项目", "B2":"金额", "A3":"甲", "B3":"100", "A4":"乙", "B4":"200", "B5":"=SUM(B1:B4)"]
    cases.append(TableLayoutCase(name: "range-starts-at-title", cells: titled, column: 1, header: 1, rows: 2, sum: 300, total: 4,
        names: ["项目", "金额"]))
    cases.append(TableLayoutCase(name: "range-starts-at-title-labelled", cells: titled.merging(["A5": "合计金额"]) { $1 },
        column: 1, header: 1, rows: 2, sum: 300, total: 4, names: ["项目", "金额"]))
    // 第四次审查：表头里的数字年份、TRUE 也被 SUM 包进去，这一行仍是合计，明细只有 300。表头格不是文字，列名用列字母。
    for (name, year, label) in [("numeric-year", "2026", ""), ("numeric-year-合计", "2026", "合计"),
                                ("numeric-year-合计金额", "2026", "合计金额"), ("boolean-header", "TRUE", "")] {
        var cells = ["A1":"项目", "B1":"地区", "C1":"颜色", "D1":year, "A2":"甲", "B2":"East", "C2":"Blue", "D2":"100",
                     "A3":"乙", "B3":"West", "C3":"Red", "D3":"200", "D4":"=SUM(D1:D3)"]
        if !label.isEmpty { cells["A4"] = label }
        cases.append(TableLayoutCase(name: name, cells: cells, column: 3, header: 0, rows: 2, sum: 300, total: 3,
            names: ["项目", "地区", "颜色", "D"]))
    }
    // 首条记录在有字的列里全是文字：缺格、横向合并都不让它变成第二行表头。
    for (name, cells, column, merges) in [
        ("review-merged-three-columns", ["A1": "Name", "C1": "Color", "D1": "Amount", "A2": "Alice", "C2": "Blue", "D2": "100", "A3": "Bob", "C3": "Red", "D3": "200"], 3, ["A1:B1"]),
        ("review-sparse-alice", ["A1":"Name", "C1":"Color", "D1":"Amount", "A2":"Alice", "B2":"East", "C2":"Blue", "D2":"100", "A3":"Bob", "B3":"West", "C3":"Red", "D3":"200"], 3, []),
        ("review-merged-alice", ["A1":"Name", "C1":"Color", "D1":"Team", "E1":"Amount", "A2":"Alice", "C2":"Blue", "D2":"East", "E2":"100", "A3":"Bob", "C3":"Red", "D3":"West", "E3":"200"], 4, ["A1:B1"]),
        ("formula-text-record", ["A1":"Name", "C1":"Color", "D1":"Amount", "A2":"Alice", "B2":"=\"East\"", "C2":"Blue", "D2":"=100", "A3":"Bob", "B3":"West", "C3":"Red", "D3":"200"], 3, [])
    ] {
        let names = name == "review-merged-alice" ? ["Name", "B", "Color", "Team", "Amount"] : ["Name", "B", "Color", "Amount"]
        cases.append(TableLayoutCase(name: name, cells: cells, column: column, header: 0, rows: 2, sum: 300, total: nil,
            names: names, merges: merges))
    }
    for merges in [[], ["A1:B1"]] {
        cases.append(TableLayoutCase(name: "text-first-record-\(merges.isEmpty ? "sparse" : "merged")",
            cells: ["A1":"Name", "C1":"Color", "D1":"Amount", "A2":"Alice", "B2":"East", "C2":"Blue",
                    "A3":"Bob", "B3":"West", "C3":"Red", "D3":"200"],
            column: 3, header: 0, rows: 2, sum: 200, total: nil, names: ["Name", "B", "Color", "Amount"],
            merges: merges, values: 1))
    }
    // 第四次审查：金额写着「待结算」之类的首条记录，合并格盖住数字列也一样，Alice 留着、列名不变。
    for marker in ["—", "待结算", "N/A"] {
        cases.append(TableLayoutCase(name: "merged-text-record-" + marker,
            cells: ["A1":"Name", "C1":"Amount", "A2":"Alice", "B2":"East", "C2":marker, "A3":"Bob", "B3":"West", "C3":"200"],
            column: 2, header: 0, rows: 2, sum: 200, total: nil, names: ["Name", "B", "Amount"], merges: ["A1:B1"], type: "mixed"))
    }
    cases.append(TableLayoutCase(name: "merged-text-record-numbers-under-group",
        cells: ["A1":"Name", "B1":"Amount", "A2":"Alice", "B2":"待核", "C2":"待结算", "A3":"Bob", "B3":"100", "C3":"200"],
        column: 2, header: 0, rows: 2, sum: 200, total: nil, names: ["Name", "Amount", "C"], merges: ["B1:C1"], type: "mixed"))
    return cases
}

func tableLayoutWorkbook(_ item: TableLayoutCase) -> Workbook {
    var sheet = makeSheet("S", id: 1, item.cells)
    sheet.merges = item.merges.map { CellRange(a1: $0)! }
    if let cached = item.cached {
        sheet.cells[CellAddress(a1: cached.address)!] = Cell(value: .number(cached.value),
            formula: CellFormula(source: cached.source, cachedValue: .number(cached.value)))
    }
    var book = Workbook(sheets: [sheet, makeSheet("Other", id: 2, ["B2": "20", "B3": "30", "B4": "40"])])
    if let format = item.format { book.restyle(CellRange(sheet.contentRange!.end), sheet: 0, Workbook.CellStyleChange(numberFormat: format)) }
    Recalculator.recalculate(&book)
    return book
}

@MainActor
func tableLayoutChecks() {
    for item in tableLayoutCases() {
        group("table layout: \(item.name)") {
            let book = tableLayoutWorkbook(item)
            let block = TableBlocks.find(in: book.sheets[0])[0]
            checkEqual(block.headerRow, item.header, "header")
            checkEqual(block.totalsRow, item.total, "total")
            checkEqual(block.columns.map(\.name), item.names, "column names")
            guard let rows = block.dataRows else { fail("missing data rows"); return }
            let summary = ColumnSummary(column: item.column, rows: rows, in: book.sheets[0], styles: book.styles, dateSystem: book.dateSystem)
            checkEqual(summary.type, item.type, "describe type")
            checkEqual(summary.count, item.values ?? item.rows, "describe count")
            checkEqual(summary.sum, item.sum, "describe sum")
            let column = block.columns.first { $0.index == item.column }!.name.replacingOccurrences(of: "\"", with: "\"\"")
            let sql = try SQLQuery.run("SELECT count(*), sum(\"\(column)\") FROM S", tables: QueryTables.tables(for: book))
            checkEqual(sql.rows[0][0], .integer(Int64(item.rows)), "SQL count")
            if case .real(let value) = sql.rows[0][1] {
                let expected = DecimalMath.double(item.sum)
                check(abs(value - expected) <= max(1, abs(expected)) * 1e-12, "SQL sum \(value), expected \(expected)")
            } else { fail("missing SQL sum") }
        }
    }
}
