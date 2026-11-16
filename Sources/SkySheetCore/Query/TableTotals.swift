import Foundation

/// 名字只能提示意图；排除整行会改变 SQL 和统计，所以必须同时有可核对的汇总证据。
enum TableTotals {
    private static let labels: Set<String> = ["合计", "总计", "小计", "汇总", "共计", "total", "subtotal", "grandtotal", "sum"]

    private static func label(_ cell: Cell?) -> String? {
        guard let cell, cell.formula == nil, case .text(let text) = cell.value else { return nil }
        return text.filter { !$0.isWhitespace && $0 != ":" && $0 != "：" }.lowercased()
    }

    /// `tableTop` 是整块的第一行（含标题、表头），求和范围不能越出本块。
    static func confirmed(row: Int, firstDataRow: Int, tableTop: Int, columns: [Int],
                          in sheet: Sheet, styles: StyleTable, dateSystem: DateSystem) -> Bool {
        if columns.contains(where: { column in
            guard let source = sheet.cells[row, column]?.formula?.source,
                  let start = completeSumStart(source, column: column, row: row, sheet: sheet.name),
                  (tableTop...firstDataRow).contains(start) else { return false }
            // SUM 忽略文字：范围往上多包的标题、表头只要没有数字，就不改变合计，照样是完整汇总。
            return (start..<firstDataRow).allSatisfy { index in
                switch sheet.cells[index, column]?.value ?? .empty {
                case .empty, .text: return true
                default: return false
                }
            }
        }) { return true }
        guard row - firstDataRow >= 2,
              columns.contains(where: { label(sheet.cells[row, $0]).map(labels.contains) == true }) else { return false }
        return columns.contains { column in
            guard let cell = sheet.cells[row, column], case .number(let value) = cell.value, !value.isNaN else { return false }
            var sum: Decimal = 0
            var numbers = 0
            for index in firstDataRow..<row {
                switch sheet.cells[index, column]?.value ?? .empty {
                case .number(let number): sum += number; numbers += 1
                case .error: return false
                default: break
                }
            }
            let code = styles.formatCode(forStyle: cell.styleIndex)
            let section = FormatCodeCache.shared.parsed(code).section(for: value).section
            guard numbers > 0, !sum.isNaN, section.kind == .number || section.kind == .general else { return false }
            let shown = ValueFormatter.format(.number(value), code: code, dateSystem: dateSystem).text
            // 同一格式比较总和再显示，不能先逐格舍入；错误占位也不能当成吻合的数字。
            return shown != DateRenderer.invalid && !shown.isEmpty
                && shown == ValueFormatter.format(.number(sum), code: code, dateSystem: dateSystem).text
        }
    }

    /// 同表同列、连续不重叠、正好加到上一行的 SUM / SUBTOTAL(9 或 109)：返回范围的起始行，起点由调用方核对。
    private static func completeSumStart(_ source: String, column: Int, row: Int, sheet: String) -> Int? {
        var arguments: [FormulaNode]
        if case .call(let name, let nodes) = try? FormulaParser.parse(source), name == "SUM" || name == "SUBTOTAL" {
            arguments = nodes
            if name == "SUBTOTAL" {
                guard case .number(let code)? = arguments.first, code == 9 || code == 109 else { return nil }
                arguments.removeFirst()
            }
        } else {
            // 分词失败时只剥 SUBTOTAL 的外壳，仍核对实际范围。结构化名称没有区域元数据，不能仅凭编号排除。
            let pattern = #"^\s*=?\s*SUBTOTAL\s*\(\s*(?:9|109)\s*[,;]\s*(.+)\)\s*$"#
            guard let match = source.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
                  match == source.startIndex..<source.endIndex,
                  let start = source.firstIndex(where: { $0 == "," || $0 == ";" }),
                  let end = source.lastIndex(of: ")"),
                  let node = try? FormulaParser.parse(String(source[source.index(after: start)..<end])) else { return nil }
            arguments = [node]
        }
        guard !arguments.isEmpty else { return nil }
        var ranges: [CellRange] = []
        for node in arguments {
            guard case .reference(let reference) = node,
                  reference.sheet == nil || reference.sheet?.caseInsensitiveCompare(sheet) == .orderedSame,
                  reference.range.start.column == column, reference.range.end.column == column else { return nil }
            ranges.append(reference.range)
        }
        ranges.sort { $0.start.row < $1.start.row }
        guard let first = ranges.first else { return nil }
        var next = first.start.row
        for range in ranges {
            guard range.start.row == next, range.end.row < row else { return nil }
            next = range.end.row + 1
        }
        return next == row ? first.start.row : nil
    }

    /// 前缀只负责提示，绝不参与 confirmed 的标签证据。
    static func suspected(row: Int, columns: [Int], in sheet: Sheet) -> Bool {
        columns.contains { column in
            if let text = label(sheet.cells[row, column]), labels.contains(where: text.hasPrefix) { return true }
            guard let source = sheet.cells[row, column]?.formula?.source,
                  source.range(of: #"\b(SUM|SUBTOTAL)\s*\("#, options: [.regularExpression, .caseInsensitive]) != nil else { return false }
            guard let node = try? FormulaParser.parse(source) else { return true }
            func above(_ node: FormulaNode) -> Bool {
                switch node {
                case .reference(let reference): return reference.range.end.row < row
                case .call(_, let arguments): return arguments.contains(where: above)
                case .negate(let node), .unaryPlus(let node), .percent(let node): return above(node)
                case .binary(_, let left, let right), .dynamicRange(let left, let right): return above(left) || above(right)
                default: return false
                }
            }
            return above(node)
        }
    }
}
