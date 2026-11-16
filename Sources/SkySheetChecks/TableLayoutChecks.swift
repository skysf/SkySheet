import Foundation
import SkySheetCore

/// 同一份生成输入也链接 main 的内核运行；期望来自已知数据行，不能用被测启发式反推。
struct TableLayoutCase {
    var name: String
    var cells: [String: String]
    var column: Int
    var header: Int?
    var rows: Int
    var sum: Decimal
    var total: Int?
    var merges: [String] = []
    var cached: (address: String, source: String, value: Decimal)?
    var format: String? = nil
    var warning = false
    var improvement: String? = nil
}

func tableLayoutCases() -> [TableLayoutCase] {
    var cases: [TableLayoutCase] = []
    for layout in ["single", "sparse", "merged", "two-headers", "numbered"] {
        for count in [2, 3, 5] {
            var cells: [String: String] = [:]
            let header = layout == "two-headers" ? 1 : 0
            let column = layout == "numbered" ? 2 : layout == "merged" ? 4 : 3
            let names = layout == "numbered" ? ["序号", "项目", "金额"]
                : layout == "merged" ? ["项目", "", "颜色", "地区", "金额"] : ["项目", "地区", "颜色", "金额"]
            if header == 1 { cells = ["A1": "基本", "C1": "还款"] }
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
            for kind in ["no-total", "sum-data", "sum-header", "literal-total"] {
                var input = cells
                if kind != "no-total" {
                    input[CellAddress(row: bottom, column: layout == "numbered" ? 1 : 0).a1] = "合计"
                    input[CellAddress(row: bottom, column: column).a1] = kind == "literal-total" ? String(sum)
                        : "=SUM(\(letter)\(kind == "sum-header" ? header + 1 : header + 2):\(letter)\(bottom))"
                }
                let reason = header == 1 ? "分组表头后的纯文字行才是列名，main 会把它计入数据并使用分组名。"
                    : kind == "literal-total" ? "精确合计标签和至少两行的数字和吻合，排除重复累计。" : nil
                cases.append(TableLayoutCase(name: "\(layout)-\(count)-\(kind)", cells: input, column: column,
                    header: header, rows: count, sum: Decimal(sum), total: kind == "no-total" ? nil : bottom,
                    merges: layout == "merged" ? ["A1:B1"] : [], improvement: reason))
            }
        }
    }
    let base = ["A1": "项目", "B1": "金额", "A2": "甲", "B2": "100", "A3": "乙", "B3": "200", "A4": "丙", "B4": "300"]
    func append(_ name: String, _ extra: [String: String], rows: Int = 3, sum: Decimal = 600, total: Int? = 4,
                warning: Bool = false, reason: String? = nil, cached: (String, String, Decimal)? = nil, format: String? = nil) {
        cases.append(TableLayoutCase(name: name, cells: base.merging(extra) { $1 }, column: 1, header: 0,
            rows: rows, sum: sum, total: total, cached: cached, format: format, warning: warning, improvement: reason))
    }
    // 两位审查者列出的标签、绝对引用、同表引用、结构化缓存以及 ROUND 包装全部保留。
    for label in ["合计", "总计", "小计", "汇总", "共计", "合计：", "合 计", "合　计", "Total", "Subtotal", " Grand Total : ", "Sum", "合计金额"] {
        append("review-label-\(label)", ["A5": label, "B5": "=SUM(B1:B4)"])
    }
    for source in ["SUM(B2:B4)", "SUM($B$2:$B$4)", "SUM(B$2:B4)", "SUM(S!B2:B4)", "SUM(B1:B4)",
                   "SUBTOTAL(9,B2:B4)", "SUBTOTAL(109,B1:B4)", "SUBTOTAL(9;B2:B4)", "SUM(B2:B2,B3:B4)"] {
        append("review-formula-\(source)", ["B5": "=" + source])
    }
    for code in [9, 109] {
        for label in ["汇总", "Total", "item"] {
            let source = "SUBTOTAL(\(code),表1[金额])"
            let kept = label == "item"
            append("review-structured-\(code)-\(label)", ["A5": label], rows: kept ? 4 : 3, sum: kept ? 1200 : 600,
                total: kept ? nil : 4, warning: kept,
                reason: kept ? "结构化引用缺少区域元数据且没有精确标签，编号不能证明范围，保留缓存值并提示。" : nil,
                cached: ("B5", source, 600))
        }
    }
    append("review-round-sum", ["A5": "合计：", "B5": "=ROUND(SUM(B2:B4),2)"],
           reason: "ROUND 包装仍可凭精确标签与数值和确认，main 会重复累计。")
    for label in ["合计划款", "汇总表", "Summer", "Sumner", "Total Quality Management", "Summary account", "合计"] {
        for numbered in [false, true] {
            let cells = numbered ? ["A1": "序号", "B1": "项目", "C1": "金额", "A2": "1", "B2": "甲", "C2": "100", "A3": "2", "B3": label, "C3": "200"]
                : ["A1": "项目", "B1": "金额", "A2": "甲", "B2": "100", "A3": label, "B3": "200"]
            cases.append(TableLayoutCase(name: "review-ordinary-\(label)-\(numbered)", cells: cells, column: numbered ? 2 : 1,
                header: 0, rows: 2, sum: 300, total: nil, warning: true))
        }
    }
    cases.append(TableLayoutCase(name: "review-numeric-coincidence", cells: base, column: 1, header: 0, rows: 3, sum: 600, total: nil))
    for header in [false, true] {
        cases.append(TableLayoutCase(name: "review-one-numeric-column-\(header)", cells: header
            ? ["A1": "金额", "A2": "100", "A3": "200", "A4": "300"] : ["A1": "100", "A2": "200", "A3": "300"],
            column: 0, header: nil, rows: 3, sum: 600, total: nil))
    }
    cases.append(TableLayoutCase(name: "review-merged-three-columns", cells: ["A1": "Name", "C1": "Color", "D1": "Amount",
        "A2": "Alice", "C2": "Blue", "D2": "100", "A3": "Bob", "C3": "Red", "D3": "200"], column: 3,
        header: 0, rows: 2, sum: 300, total: nil, merges: ["A1:B1"]))
    for (source, value) in [("SUM(1,2)", 3), ("SUM(B3:B4)", 500), ("SUM(B2:B3)", 300), ("SUM(C5:D5)", 0),
                            ("SUM(Other!B2:B4)", 90), ("SUBTOTAL(1,B2:B4)", 200), ("SUM(B2,3)", 103),
                            ("SUM(B2:B4,B2:B4)", 1200), ("SUM(B1:B3)", 300)] {
        append("review-retain-\(source)", ["B5": "=" + source], rows: 4, sum: Decimal(600 + value), total: nil,
            warning: !["SUM(1,2)", "SUM(C5:D5)"].contains(source),
            reason: "常量、横向、跨表、非求和 SUBTOTAL 或不完整/重复范围没有完整竖向求和证据，保留数据。",
            cached: source == "SUBTOTAL(1,B2:B4)" ? ("B5", source, 200) : nil)
    }
    append("review-before-header", ["B5": "=SUM(B1:B4)"])
    append("precision-rounded-total", ["A5": "合计", "B5": "600.004"], reason: "按合计格的显示精度比较，避免金额尾差导致重复累计。", format: "0.00")
    append("precision-mismatch", ["A5": "合计", "B5": "600.006"], rows: 4, sum: Decimal(string: "1200.006")!, total: nil,
        warning: true, format: "0.00")
    append("prefix-with-equal-sum", ["A5": "Summer", "B5": "600"], rows: 4, sum: 1200, total: nil, warning: true)
    for (name, cells, column, merges) in [
        ("review-sparse-alice", ["A1":"Name", "C1":"Color", "D1":"Amount", "A2":"Alice", "B2":"East", "C2":"Blue", "D2":"100", "A3":"Bob", "B3":"West", "C3":"Red", "D3":"200"], 3, []),
        ("review-merged-alice", ["A1":"Name", "C1":"Color", "D1":"Team", "E1":"Amount", "A2":"Alice", "C2":"Blue", "D2":"East", "E2":"100", "A3":"Bob", "C3":"Red", "D3":"West", "E3":"200"], 4, ["A1:B1"]),
        ("formula-text-record", ["A1":"Name", "C1":"Color", "D1":"Amount", "A2":"Alice", "B2":"=\"East\"", "C2":"Blue", "D2":"=100", "A3":"Bob", "B3":"West", "C3":"Red", "D3":"200"], 3, [])
    ] {
        cases.append(TableLayoutCase(name: name, cells: cells, column: column, header: 0, rows: 2, sum: 300, total: nil, merges: merges))
    }
    let small = ["A1":"项目", "B1":"金额", "A2":"甲", "B2":"1", "A3":"乙", "B3":"2"]
    for (source, value) in [("SUM(B3:B3)", 2), ("SUM(B2:B2)", 1), ("SUM(B2,3)", 4), ("ROUND(SUM(B3:B3),2)", 2), ("SUM (B3:B3)+1", 3)] {
        cases.append(TableLayoutCase(name: "review-small-" + source, cells: small.merging(["B4":"=" + source]) { $1 },
            column: 1, header: 0, rows: 3, sum: Decimal(3 + value), total: nil,
            cached: source == "SUM (B3:B3)+1" ? ("B4", source, 3) : nil, warning: true,
            improvement: "不完整范围或包装的部分求和不是汇总全表，保留数据并提示。"))
    }
    for label in ["合计", "总计", "小计", "汇总", "共计", "Total", "Subtotal", " Grand Total : ", "Sum", "合　计："] {
        append("exact-numeric-" + label, ["A5":label, "B5":"600"], reason: "精确标签和数字和同时吻合，main 缺少数值汇总识别而重复累计。")
    }
    cases.append(TableLayoutCase(name: "one-prior-record-is-insufficient", cells: ["A1":"项目", "B1":"金额", "A2":"甲", "B2":"100", "A3":"Total", "B3":"100"],
        column: 1, header: 0, rows: 2, sum: 200, total: nil, warning: true))
    cases.append(TableLayoutCase(name: "review-constant-row-sums", cells: ["A1":"项目", "B1":"金额", "A2":"甲", "B2":"=SUM(1,2)", "A3":"乙", "B3":"=SUM(3,4)"],
        column: 1, header: 0, rows: 2, sum: 10, total: nil, improvement: "常量 SUM 属于记录本身，main 会丢掉最后一条。"))
    cases.append(TableLayoutCase(name: "review-horizontal-row-sums", cells: ["A1":"Name", "B1":"Jan", "C1":"Feb", "D1":"Total", "A2":"Alice", "B2":"1", "C2":"2", "D2":"=SUM(B2:C2)", "A3":"Bob", "B3":"3", "C3":"4", "D3":"=SUM(B3:C3)"],
        column: 1, header: 0, rows: 2, sum: 4, total: nil, improvement: "横向逐行 SUM 属于记录本身，main 会丢掉最后一条。"))
    cases.append(TableLayoutCase(name: "range-starts-before-header", cells: ["A1":"Report", "A2":"项目", "B2":"金额", "A3":"甲", "B3":"100", "A4":"乙", "B4":"200", "B5":"=SUM(B1:B4)"],
        column: 1, header: 1, rows: 3, sum: 600, total: nil, warning: true,
        improvement: "范围从标题之前开始，不能证明只汇总当前表头或数据；保留并提示。"))
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

func tableLayoutBlock(_ book: Workbook) -> TableBlock {
    #if TABLE_LAYOUT_BASELINE
    return TableBlocks.find(in: book.sheets[0])[0]
    #else
    return TableBlocks.find(in: book.sheets[0], styles: book.styles, dateSystem: book.dateSystem)[0]
    #endif
}

#if !TABLE_LAYOUT_BASELINE
@MainActor
func tableLayoutChecks() {
    for item in tableLayoutCases() {
        group("table layout: \(item.name)") {
            let book = tableLayoutWorkbook(item)
            let block = tableLayoutBlock(book)
            checkEqual(block.headerRow, item.header, "header")
            checkEqual(block.totalsRow, item.total, "total")
            guard let rows = block.dataRows else { fail("missing data rows"); return }
            let summary = ColumnSummary(column: item.column, rows: rows, in: book.sheets[0], styles: book.styles, dateSystem: book.dateSystem)
            checkEqual(summary.count, item.rows, "describe count")
            checkEqual(summary.sum, item.sum, "describe sum")
            let column = block.columns.first { $0.index == item.column }!.name.replacingOccurrences(of: "\"", with: "\"\"")
            let sql = try SQLQuery.run("SELECT count(*), sum(\"\(column)\") FROM S", tables: QueryTables.tables(for: book))
            checkEqual(sql.rows[0][0], .integer(Int64(item.rows)), "SQL count")
            if case .real(let value) = sql.rows[0][1] {
                let expected = DecimalMath.double(item.sum)
                check(abs(value - expected) <= max(1, abs(expected)) * 1e-12, "SQL sum \(value), expected \(expected)")
            } else { fail("missing SQL sum") }
            checkEqual(block.suspectedTotalsRow, item.warning ? block.range.end.row : nil, "uncertain row")
            if item.warning { checkEqual(block.note, "Row \(block.range.end.row + 1) might be a total row; it is kept as data.", "English uncertainty") }
        }
    }
}

#endif

/// 输出只写到调用者指定的临时目录；脚本比较列名、统计全部字段及 SQL，不能只比合计。
func dumpTableLayoutSnapshots() throws {
    let snapshots: [[String: Any]] = try tableLayoutCases().map { item in
        let book = tableLayoutWorkbook(item)
        let block = tableLayoutBlock(book)
        let stats: [[String: Any]] = block.columns.map { column in
            guard let rows = block.dataRows else { return [:] }
            let summary = ColumnSummary(column: column.index, rows: rows, in: book.sheets[0], styles: book.styles, dateSystem: book.dateSystem)
            return ["name": column.name, "header": column.header as Any? ?? NSNull(), "type": summary.type, "count": summary.count,
                    "sum": summary.sum.map(String.init(describing:)) as Any? ?? NSNull(), "min": summary.minimum.map(String.init(describing:)) as Any? ?? NSNull(),
                    "max": summary.maximum.map(String.init(describing:)) as Any? ?? NSNull(), "samples": summary.samples,
                    "format": summary.formatCode as Any? ?? NSNull()]
        }
        let column = block.columns.first { $0.index == item.column }!.name.replacingOccurrences(of: "\"", with: "\"\"")
        let sql = try SQLQuery.run("SELECT count(*), sum(\"\(column)\") FROM S", tables: QueryTables.tables(for: book))
        #if TABLE_LAYOUT_BASELINE
        let note: String? = block.totalsRow == nil ? nil : "The totals row is left out of the column stats and of the SQL table; read it with read_range."
        #else
        let note = block.note
        #endif
        return ["name": item.name, "improvement": item.improvement as Any? ?? NSNull(), "header": block.headerRow as Any? ?? NSNull(),
                "data": block.dataRows.map { [$0.lowerBound, $0.upperBound] } as Any? ?? NSNull(), "total": block.totalsRow as Any? ?? NSNull(),
                "stats": stats, "sql": sql.rows.map { $0.map(String.init(describing:)) }, "note": note as Any? ?? NSNull()]
    }
    let data = try JSONSerialization.data(withJSONObject: snapshots, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}
