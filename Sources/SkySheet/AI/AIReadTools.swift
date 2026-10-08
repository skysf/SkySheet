import Foundation
import SkySheetCore
import SkySheetFiles
import SkySheetMCPKit

// MARK: - 看和取的工具：describe_sheet、read_range、query、evaluate、export_sheet（设计 9.2 节）。都不改工作簿。

@MainActor
enum AIReadTools {
    static let readLimit = 2_000

    // MARK: - describe_sheet

    static func describe(_ arguments: AIToolArguments) throws -> AIToolResult {
        let context = try AIWorkbooks.context(arguments)
        let index = try context.sheetIndex(try arguments.requiredString("sheet"))
        let workbook = context.workbook
        let sheet = workbook.sheets[index]
        let blocks = TableBlocks.find(in: sheet)

        var formulas = 0
        var notRecalculated: [JSONValue] = []
        var loose: [JSONValue] = []
        sheet.cells.forEach { address, cell in
            if let formula = cell.formula {
                formulas += 1
                if case .notRecalculated(let reason) = formula.status, notRecalculated.count < 20 {
                    notRecalculated.append(["cell": .string(address.a1), "reason": .string(reason),
                                            "value_from_file": AIFormat.json(cell.value)])
                }
            }
            guard cell.value != .empty || cell.formula != nil, !blocks.contains(where: { $0.range.contains(address) }),
                  loose.count < 20 else { return }
            var item: [String: JSONValue] = ["cell": .string(address.a1), "value": AIFormat.json(cell.value)]
            if let formula = cell.formula { item["formula"] = .string("=" + formula.source) }
            loose.append(.object(item))
        }

        var payload: [String: JSONValue] = [
            "workbook": .string(context.label),
            "sheet": .string(sheet.name),
            "role": sheet.role.isAI ? "ai (you may write to it)" : "original (read-only for you)",
            "used_range": AIWorkbookTools.usedRange(sheet).map { .string($0.a1) } ?? .null,
            "formulas": .number(Double(formulas)),
            "blocks": .array(blocks.map { block(json: $0, sheet, workbook) }),
        ]
        if let frozen = sheet.frozen { payload["frozen"] = ["rows": .number(Double(frozen.rows)), "columns": .number(Double(frozen.columns))] }
        if !sheet.merges.isEmpty { payload["merged"] = .array(sheet.merges.prefix(50).map { .string($0.a1) }) }
        if !notRecalculated.isEmpty { payload["not_recalculated"] = .array(notRecalculated) }
        if !loose.isEmpty { payload["other_cells"] = .array(loose) }
        if let authorship = sheet.role.authorship { payload["by"] = .string(AIWorkbookTools.byline(authorship.created)) }
        return .ok(.object(payload))
    }

    private static func block(json block: TableBlock, _ sheet: Sheet, _ workbook: Workbook) -> JSONValue {
        var columns: [JSONValue] = []
        for column in block.columns {
            guard let rows = block.dataRows else { break }
            let summary = ColumnSummary(column: column.index, rows: rows, in: sheet, styles: workbook.styles,
                                        dateSystem: workbook.dateSystem)
            guard summary.type != "empty" else { continue }
            var item: [String: JSONValue] = [
                "column": .string(CellAddress.columnName(column.index)), "name": .string(column.name),
                "type": .string(summary.type), "count": .number(Double(summary.count)),
                "samples": .array(summary.samples.map { .string($0) }),
            ]
            if let format = summary.formatCode { item["format"] = .string(format) }
            if let sum = summary.sum {
                item["sum"] = AIFormat.json(sum)
                item["min"] = AIFormat.json(summary.minimum)
                item["max"] = AIFormat.json(summary.maximum)
            }
            columns.append(.object(item))
        }
        var item: [String: JSONValue] = [
            "table": .string(block.name), "range": .string(block.range.a1), "columns": .array(columns),
        ]
        if let title = block.title { item["title"] = .string(title) }
        if let header = block.headerRow { item["header_row"] = .number(Double(header + 1)) }
        if let rows = block.dataRows { item["data_rows"] = .string("\(rows.lowerBound + 1)-\(rows.upperBound + 1)") }
        if let totals = block.totalsRow {
            item["totals_row"] = .number(Double(totals + 1))
            item["note"] = "The totals row is left out of the column stats and of the SQL table; read it with read_range."
        }
        return .object(item)
    }

    // MARK: - read_range

    static func read(_ arguments: AIToolArguments) throws -> AIToolResult {
        let context = try AIWorkbooks.context(arguments)
        let (named, range) = try AIFormat.range(try arguments.requiredString("range"))
        let index = try (named ?? arguments.string("sheet")).map(context.sheetIndex) ?? context.session.sheetIndex
        guard range.rowCount * range.columnCount <= readLimit else {
            throw AIToolError("""
                \(range.a1) has \(range.rowCount * range.columnCount) cells; read_range returns at most \(readLimit). \
                Read a smaller range, or use query or export_sheet for whole tables.
                """)
        }
        let extras = Set(try arguments.stringArray("include") ?? [])
        let workbook = context.workbook
        let sheet = workbook.sheets[index]
        var values: [JSONValue] = []
        var texts: [JSONValue] = []
        var formulas: [JSONValue] = []
        for row in range.start.row...range.end.row {
            var valueRow: [JSONValue] = []
            var textRow: [JSONValue] = []
            var formulaRow: [JSONValue] = []
            for column in range.start.column...range.end.column {
                let cell = sheet.cells[row, column]
                valueRow.append(AIFormat.json(cell?.value ?? .empty))
                if extras.contains("text") {
                    let shown = cell.map {
                        ValueFormatter.format($0.value, code: workbook.styles.formatCode(forStyle: $0.styleIndex),
                                              dateSystem: workbook.dateSystem).text
                    }
                    textRow.append(shown.map { .string($0) } ?? .null)
                }
                if extras.contains("formulas") { formulaRow.append(cell?.formula.map { .string("=" + $0.source) } ?? .null) }
            }
            values.append(.array(valueRow))
            texts.append(.array(textRow))
            formulas.append(.array(formulaRow))
        }
        var payload: [String: JSONValue] = [
            "workbook": .string(context.label), "sheet": .string(sheet.name), "range": .string(range.a1),
            "values": .array(values),
        ]
        if extras.contains("text") { payload["text"] = .array(texts) }
        if extras.contains("formulas") { payload["formulas"] = .array(formulas) }
        return .ok(.object(payload))
    }

    // MARK: - query

    static func query(_ arguments: AIToolArguments) throws -> AIToolResult {
        let context = try AIWorkbooks.context(arguments)
        let sql = try arguments.requiredString("sql")
        var extra: [(name: String, sheet: Int, range: CellRange)] = []
        for (name, value) in try arguments.object("tables") ?? [:] {
            guard let text = value.stringValue else { throw AIToolError("tables.\(name) must be a range like Loan!A1:J20.") }
            let (sheetName, range) = try AIFormat.range(text)
            extra.append((name, try sheetName.map(context.sheetIndex) ?? context.session.sheetIndex, range))
        }
        let tables = QueryTables.tables(for: context.workbook, extra: extra)
        do {
            let result = try SQLQuery.run(sql, tables: tables)
            return .ok([
                "columns": .array(result.columns.map { .string($0) }),
                "rows": .array(result.rows.map { .array($0.map(json)) }),
                "row_count": .number(Double(result.rows.count)),
                "truncated": .bool(result.truncated),
            ])
        } catch {
            let available = tables.map { table in
                "\(table.name)(\(table.columns.prefix(30).joined(separator: ", ")))"
            }.joined(separator: "; ")
            throw AIToolError("The query failed: \(error.message). Tables: \(available.isEmpty ? "none" : available).")
        }
    }

    private static func json(_ value: SQLQuery.Value) -> JSONValue {
        switch value {
        case .null: .null
        case .integer(let number): .number(Double(number))
        case .real(let number): .number(number)
        case .text(let text): .string(text)
        }
    }

    // MARK: - evaluate

    static func evaluate(_ arguments: AIToolArguments) throws -> AIToolResult {
        let context = try AIWorkbooks.context(arguments)
        let formula = try arguments.requiredString("formula")
        let index = try arguments.string("sheet").map(context.sheetIndex) ?? context.session.sheetIndex
        switch FormulaEvaluation.evaluate(formula, in: context.workbook, sheet: index) {
        case .value(let value):
            var payload: [String: JSONValue] = ["formula": .string(formula.hasPrefix("=") ? formula : "=" + formula),
                                                "value": AIFormat.json(value)]
            if case .number(let number) = value { payload["text"] = .string(ValueFormatter.general(number)) }
            return .ok(.object(payload))
        case .unsupported(let reason):
            throw AIToolError("SkySheet can't calculate this formula: \(reason).")
        }
    }

    // MARK: - export_sheet

    static func export(_ arguments: AIToolArguments) throws -> AIToolResult {
        let context = try AIWorkbooks.context(arguments)
        let index = try context.sheetIndex(try arguments.requiredString("sheet"))
        let workbook = context.workbook
        let sheet = workbook.sheets[index]
        let range = try arguments.string("range").map { try AIFormat.range($0).range }
            ?? AIWorkbookTools.usedRange(sheet).map { CellRange(CellAddress(row: 0, column: 0), $0.end) }
        guard let range else { throw AIToolError("\(sheet.name) is empty: there is nothing to export.") }
        let data = CSVWriter.analysisData(sheet, range: range, styles: workbook.styles, dateSystem: workbook.dateSystem)
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ai.skylu.skysheet/exports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let base = "\(context.label)-\(sheet.name)-\(stamp)".map { "/:".contains($0) ? "-" : $0 }
        let url = folder.appendingPathComponent(String(base) + ".csv")
        try data.write(to: url)
        let header = (range.start.column...range.end.column).map { column -> JSONValue in
            AIFormat.json(sheet.cells[range.start.row, column]?.value ?? .empty)
        }
        return .ok(["path": .string(url.path), "rows": .number(Double(range.rowCount)),
                    "columns": .number(Double(range.columnCount)), "first_row": .array(header),
                    "range": .string(range.a1)])
    }
}
