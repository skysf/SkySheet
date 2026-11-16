import Foundation

/// 名字只能提示意图；排除整行会改变 SQL 和统计，所以必须同时有可核对的汇总证据。
enum TableTotals {
    private static let labels: Set<String> = ["合计", "总计", "小计", "汇总", "共计", "total", "subtotal", "grandtotal", "sum"]

    private static func label(_ cell: Cell?) -> String? {
        guard let cell, cell.formula == nil, case .text(let text) = cell.value else { return nil }
        return text.filter { !$0.isWhitespace && $0 != ":" && $0 != "：" }.lowercased()
    }

    static func confirmed(row: Int, firstDataRow: Int, firstHeaderRow: Int?, columns: [Int],
                          in sheet: Sheet, styles: StyleTable, dateSystem: DateSystem) -> Bool {
        if columns.contains(where: { column in
            guard let source = sheet.cells[row, column]?.formula?.source else { return false }
            return completeSum(source, column: column, firstDataRow: firstDataRow,
                               firstHeaderRow: firstHeaderRow, row: row, sheet: sheet.name)
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

    private static func completeSum(_ source: String, column: Int, firstDataRow: Int, firstHeaderRow: Int?,
                                    row: Int, sheet: String) -> Bool {
        var arguments: [FormulaNode]
        if case .call(let name, let nodes) = try? FormulaParser.parse(source), name == "SUM" || name == "SUBTOTAL" {
            arguments = nodes
            if name == "SUBTOTAL" {
                guard case .number(let code)? = arguments.first, code == 9 || code == 109 else { return false }
                arguments.removeFirst()
            }
        } else {
            // 分词失败时只剥 SUBTOTAL 的外壳，仍核对实际范围。结构化名称没有区域元数据，不能仅凭编号排除。
            let pattern = #"^\s*=?\s*SUBTOTAL\s*\(\s*(?:9|109)\s*[,;]\s*(.+)\)\s*$"#
            guard let match = source.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
                  match == source.startIndex..<source.endIndex,
                  let start = source.firstIndex(where: { $0 == "," || $0 == ";" }),
                  let end = source.lastIndex(of: ")"),
                  let node = try? FormulaParser.parse(String(source[source.index(after: start)..<end])) else { return false }
            arguments = [node]
        }
        guard !arguments.isEmpty else { return false }
        var ranges: [CellRange] = []
        for node in arguments {
            guard case .reference(let reference) = node,
                  reference.sheet == nil || reference.sheet?.caseInsensitiveCompare(sheet) == .orderedSame,
                  reference.range.start.column == column, reference.range.end.column == column else { return false }
            ranges.append(reference.range)
        }
        ranges.sort { $0.start.row < $1.start.row }
        guard let first = ranges.first, ((firstHeaderRow ?? firstDataRow)...firstDataRow).contains(first.start.row) else { return false }
        var next = first.start.row
        for range in ranges {
            guard range.start.row == next, range.end.row < row else { return false }
            next = range.end.row + 1
        }
        return next == row
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
