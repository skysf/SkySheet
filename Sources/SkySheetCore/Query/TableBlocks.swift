import Foundation

/// 一张 sheet 里认出来的一个表格块（设计 9.2 节 describe_sheet、query）：一段连续有内容的行（整行空着就断开），
/// 顶上可能有一行标题（单独一格文字，如「参考选项」），再下面可能有表头（一行几乎全是文字）。
public struct TableBlock: Sendable, Equatable {
    public struct Column: Sendable, Equatable {
        /// 在 sheet 里是第几列（从 0 开始）。
        public var index: Int
        /// SQL 里的列名：表头文字；没有表头、表头空着或者重名时用列字母（重名的加 _2）。
        public var name: String
        /// 表头原文（没有表头是 nil）。
        public var header: String?
    }

    /// SQL 里的表名：第一块用 sheet 名，后面的加 _2、_3。
    public var name: String
    /// 整块（含标题、表头）。
    public var range: CellRange
    public var title: String?
    public var headerRow: Int?
    /// 数据行（只有标题、表头时是 nil）。不含合计行。
    public var dataRows: ClosedRange<Int>?
    /// 块的最后一行明确标了合计，或竖向加总上方数据：不算数据，免得查询重复累计。
    public var totalsRow: Int?
    /// 疑似合计仍参与计算，但必须向 AI 披露，不能静默把推断当事实。
    public var suspectedTotalsRow: Int? = nil
    public var note: String? {
        if totalsRow != nil { return "The totals row is left out of the column stats and of the SQL table; read it with read_range." }
        return suspectedTotalsRow.map { "Row \($0 + 1) looks like a totals row and was not excluded from the column stats or SQL table; inspect it before aggregating." }
    }
    public var columns: [Column]
}

public enum TableBlocks {
    /// 有内容的格子：有值或者有公式。只有样式的空格子不算（腾讯文档常给一整片空格子刷样式）。
    static func hasContent(_ cell: Cell) -> Bool {
        cell.value != .empty || cell.formula != nil
    }

    /// 认出一张 sheet 里的表格块。只有一格的零碎内容不算块（describe_sheet 另外列出来）。
    public static func find(in sheet: Sheet) -> [TableBlock] {
        var columnsByRow: [Int: [Int]] = [:]
        sheet.cells.forEach { address, cell in
            if hasContent(cell) { columnsByRow[address.row, default: []].append(address.column) }
        }
        var groups: [[Int]] = []
        for row in columnsByRow.keys.sorted() {
            if let last = groups.last?.last, row == last + 1 {
                groups[groups.count - 1].append(row)
            } else {
                groups.append([row])
            }
        }
        var blocks: [TableBlock] = []
        for rows in groups {
            let columns = rows.flatMap { columnsByRow[$0] ?? [] }
            guard columns.count > 1, let first = columns.min(), let last = columns.max() else { continue }
            var remaining = rows[...]
            var title: String?
            if remaining.count > 1, let top = remaining.first, columnsByRow[top]?.count == 1,
               let only = columnsByRow[top]?.first, case .text(let text)? = sheet.cells[top, only]?.value,
               sheet.cells[top, only]?.formula == nil {
                title = text
                remaining = remaining.dropFirst()
            }
            var headerRow: Int?
            if remaining.count > 1, let top = remaining.first, looksLikeHeader(row: top, columns: columnsByRow[top] ?? [], sheet) {
                headerRow = top
                remaining = remaining.dropFirst()
                // 只有分组行少列或横向合并的证据才吃第二行表头，不能把全是文字的普通记录吞掉。
                let merged = sheet.merges.contains { $0.start.row == top && $0.end.column > $0.start.column }
                let grouped = (columnsByRow[top]?.count ?? 0) < last - first + 1 || merged
                if grouped, remaining.count > 1, let next = remaining.first,
                   merged || (columnsByRow[next]?.count ?? 0) > (columnsByRow[top]?.count ?? 0),
                   looksLikeHeader(row: next, columns: columnsByRow[next] ?? [], sheet) {
                    headerRow = next
                    remaining = remaining.dropFirst()
                }
            }
            var totalsRow: Int?
            if remaining.count > 1, let bottom = remaining.last,
               isTotals(row: bottom, firstDataRow: remaining.first!,
                        columns: columnsByRow[bottom] ?? [], sheet) {
                totalsRow = bottom
                remaining = remaining.dropLast()
            }
            let suspected = totalsRow == nil ? remaining.last.flatMap { row in
                looksLikeTotals(row: row, columns: columnsByRow[row] ?? [], sheet) ? row : nil
            } : nil
            let name = blocks.isEmpty ? sheet.name : "\(sheet.name)_\(blocks.count + 1)"
            blocks.append(TableBlock(
                name: name, range: CellRange(CellAddress(row: rows[0], column: first), CellAddress(row: rows[rows.count - 1], column: last)),
                title: title, headerRow: headerRow,
                dataRows: remaining.first.map { $0...remaining[remaining.endIndex - 1] }, totalsRow: totalsRow,
                suspectedTotalsRow: suspected,
                columns: namedColumns(first...last, headerRow: headerRow, sheet)))
        }
        return blocks
    }

    /// 指定一块区域当表（query 的 tables 参数）：第一行是表头。
    public static func block(_ range: CellRange, named name: String, in sheet: Sheet) -> TableBlock {
        let data = range.start.row < range.end.row ? (range.start.row + 1)...range.end.row : nil
        return TableBlock(name: name, range: range, title: nil, headerRow: range.start.row, dataRows: data, totalsRow: nil,
                          columns: namedColumns(range.start.column...range.end.column, headerRow: range.start.row, sheet))
    }

    /// 标签可以出现在序号后面；去掉排版空白和冒号后识别前缀，兼容 Excel / WPS 的汇总行。
    private static func isTotals(row: Int, firstDataRow: Int, columns: [Int], _ sheet: Sheet) -> Bool {
        for column in columns {
            guard let cell = sheet.cells[row, column] else { continue }
            if cell.formula == nil, case .text(let text) = cell.value {
                let label = text.filter { !$0.isWhitespace }.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":："))
                if ["汇总", "共计", "合计", "总计", "小计", "total", "sum", "subtotal", "grandtotal"].contains(where: label.hasPrefix) {
                    return true
                }
            }
            guard let source = cell.formula?.source else { continue }
            // 结构化引用不在公式解析器的支持范围里；SUBTOTAL 的求和编号本身已能证明汇总意图。
            if source.range(of: #"^\s*=?\s*SUBTOTAL\s*\(\s*(9|109)\s*[,;]"#, options: [.regularExpression, .caseInsensitive]) != nil {
                return true
            }
            guard case .call("SUM", let arguments) = try? FormulaParser.parse(source), !arguments.isEmpty else { continue }
            if arguments.allSatisfy({ node in
                guard case .reference(let reference) = node,
                      reference.sheet == nil || reference.sheet?.caseInsensitiveCompare(sheet.name) == .orderedSame else { return false }
                let range = reference.range
                return range.start.column == column && range.end.column == column
                    && range.start.row <= firstDataRow && range.end.row == row - 1
            }) { return true }
        }
        return false
    }

    /// 有竖向汇总的迹象但范围不完整、跨表或公式不支持时，保留数据并给模型一个可核实的提示。
    private static func looksLikeTotals(row: Int, columns: [Int], _ sheet: Sheet) -> Bool {
        columns.contains { column in
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

    /// 表头：至少两格文字，文字占这一行有内容的格子的四分之三以上（表头旁边常有一两个零碎的数）。
    private static func looksLikeHeader(row: Int, columns: [Int], _ sheet: Sheet) -> Bool {
        let texts = columns.filter { column in
            guard let cell = sheet.cells[row, column], cell.formula == nil, case .text = cell.value else { return false }
            return true
        }
        return texts.count >= 2 && texts.count * 4 >= columns.count * 3
    }

    private static func namedColumns(_ span: ClosedRange<Int>, headerRow: Int?, _ sheet: Sheet) -> [TableBlock.Column] {
        // SQLite 区分规范等价的列名；误当重名加后缀后，按原表头查询会找不到列。
        var used: Set<ExactText> = [ExactText("_row")]
        return span.map { column in
            let header = headerRow.flatMap { row -> String? in
                guard case .text(let text)? = sheet.cells[row, column]?.value else { return nil }
                let cleaned = text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                return cleaned.isEmpty ? nil : cleaned
            }
            var name = header ?? CellAddress.columnName(column)
            if used.contains(ExactText(name.lowercased())) {
                var number = 2
                while used.contains(ExactText("\(name)_\(number)".lowercased())) { number += 1 }
                name = "\(name)_\(number)"
            }
            used.insert(ExactText(name.lowercased()))
            return TableBlock.Column(index: column, name: name, header: header)
        }
    }
}

/// 一列数据的概况（describe_sheet）：类型、格式、个数、几个样例、数字的合计和最值。
public struct ColumnSummary: Sendable, Equatable {
    /// number、date、text、bool、mixed、empty。
    public var type: String
    public var count: Int
    public var formatCode: String?
    public var samples: [String]
    public var sum: Decimal?
    public var minimum: Decimal?
    public var maximum: Decimal?

    public init(column: Int, rows: ClosedRange<Int>, in sheet: Sheet, styles: StyleTable, dateSystem: DateSystem) {
        var kinds: Set<String> = []
        var count = 0
        var samples: [String] = []
        var numbers: [Decimal] = []
        var formatCode: String?
        for row in rows {
            guard let cell = sheet.cells[row, column], cell.value != .empty else { continue }
            count += 1
            let code = styles.formatCode(forStyle: cell.styleIndex)
            switch cell.value {
            case .number(let number):
                kinds.insert(ValueFormatter.isDateFormat(code) ? "date" : "number")
                numbers.append(number)
                formatCode = formatCode ?? code
            case .text: kinds.insert("text")
            case .bool: kinds.insert("bool")
            case .error: kinds.insert("error")
            case .empty: break
            }
            let shown = ValueFormatter.format(cell.value, code: code, dateSystem: dateSystem).text
            if samples.count < 3, !samples.contains(shown) { samples.append(shown) }
        }
        let meaningful = kinds.subtracting(["error"])
        type = count == 0 ? "empty" : meaningful.count == 1 ? meaningful.first! : meaningful.isEmpty ? "error" : "mixed"
        self.count = count
        self.formatCode = formatCode == "General" ? nil : formatCode
        self.samples = samples
        if type == "number" || type == "mixed", !numbers.isEmpty {
            sum = numbers.reduce(0, +)
            minimum = numbers.min()
            maximum = numbers.max()
        }
    }
}
