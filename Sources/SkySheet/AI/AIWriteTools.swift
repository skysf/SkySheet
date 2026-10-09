import Foundation
import SkySheetCore
import SkySheetFiles
import SkySheetMCPKit

// MARK: - 改东西的工具：add_sheet、write_cells、format_cells、edit_sheet、undo（设计 9.2、9.3 节）
//
// 只认 AI 的 sheet（AIContext.requireAISheet）。每个调用是一步撤销（AIContext.change），算进这一轮，
// 改到的格子淡色高亮。

@MainActor
enum AIWriteTools {
    /// AI 的 sheet 页签是紫色的：在别的软件里也看得出来（设计 9.3 节第 2 条）。
    static let tabColor = "FFAF52DE"
    static let writeLimit = 10_000
    static let formatLimit = 50_000

    // MARK: - add_sheet

    static func addSheet(_ arguments: AIToolArguments) throws -> AIToolResult {
        let context = try AIWorkbooks.context(arguments)
        let name = try arguments.requiredString("name").trimmingCharacters(in: .whitespaces)
        if let model = try arguments.string("model"), !model.isEmpty { AISession.shared.model = model }
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let role = SheetRole.ai(AIAuthorship(created: AIAuthorship.Mark(AISession.shared.author, date: now)))
        let source = try arguments.string("copy_from").map(context.sheetIndex)
        let imported = try arguments.string("from_csv").map(csvSheet)
        guard source == nil || imported == nil else { throw AIToolError("Give copy_from or from_csv, not both.") }
        var added = 0
        do {
            try context.change(String(localized: "AI: Add Sheet")) { workbook in
                if let source {
                    added = try workbook.copySheet(source, named: name)
                } else {
                    added = try workbook.addSheet(named: name, role: role)
                }
                workbook.sheets[added].role = role
                workbook.sheets[added].tabColor = tabColor
                if let imported { place(imported, into: &workbook, at: added) }
            }
        } catch let SheetEditError.invalidName(problem) {
            throw AIToolError("\(SheetCommands.message(for: problem)) Pick another name for the new sheet.")
        }
        let sheet = context.workbook.sheets[added]
        return .ok(["sheet": .string(sheet.name), "position": .number(Double(added + 1)),
                    "used_range": AIWorkbookTools.usedRange(sheet).map { .string($0.a1) } ?? .null,
                    "role": "ai (you may write to it)"], changed: true)
    }

    /// 读一个 csv 文件（pandas 的结果）成一张表：值按读 csv 的规矩转，带着它自己的样式表。
    private static func csvSheet(_ path: String) throws -> (sheet: Sheet, styles: StyleTable) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let data = FileManager.default.contents(atPath: url.path) else { throw AIToolError("There is no file at \(url.path).") }
        let document = try CSVReader.read(data, sheetName: "import")
        guard document.workbook.sheets[0].cells.count <= 200_000 else {
            throw AIToolError("That CSV has more than 200,000 cells; SkySheet imports smaller tables.")
        }
        return (document.workbook.sheets[0], document.workbook.styles)
    }

    /// 把导进来的格子放进新 sheet：日期、百分比的数字格式换成这本工作簿里的样式编号；列宽按内容定。
    private static func place(_ imported: (sheet: Sheet, styles: StyleTable), into workbook: inout Workbook, at index: Int) {
        var styleMap: [Int: Int] = [0: 0]
        imported.sheet.cells.forEach { address, cell in
            var copy = cell
            if let mapped = styleMap[cell.styleIndex] {
                copy.styleIndex = mapped
            } else {
                let code = imported.styles.formatCode(forStyle: cell.styleIndex)
                let mapped = code == "General" ? 0 : workbook.styleIndex(basedOn: 0, numberFormat: .custom(code))
                styleMap[cell.styleIndex] = mapped
                copy.styleIndex = mapped
            }
            workbook.sheets[index].cells[address] = copy
        }
        workbook.sheets[index].columns = DocumentLoader.fittedColumns(for: workbook.sheets[index], in: workbook)
    }

    // MARK: - write_cells

    static func writeCells(_ arguments: AIToolArguments) throws -> AIToolResult {
        let context = try AIWorkbooks.context(arguments)
        let index = try context.sheetIndex(try arguments.requiredString("sheet"))
        try context.requireAISheet(index)
        let start = try AIFormat.address(try arguments.requiredString("start"))
        guard let rows = try arguments.array("rows"), !rows.isEmpty else { throw AIToolError("rows is required.") }
        let dateSystem = context.workbook.dateSystem
        let inputs: [[CellInput]] = try rows.enumerated().map { rowOffset, row in
            guard case .array(let values) = row else { throw AIToolError("rows[\(rowOffset)] must be a list of values.") }
            return try values.enumerated().map { columnOffset, value in
                try input(value, dateSystem: dateSystem, at: "rows[\(rowOffset)][\(columnOffset)]")
            }
        }
        let width = inputs.map(\.count).max() ?? 0
        let lastRow = start.row + inputs.count - 1
        let fillTo = try arguments.int("fill_down_to").map { $0 - 1 }
        if let fillTo, fillTo <= lastRow {
            throw AIToolError("fill_down_to (\(fillTo + 1)) must be below the last written row (\(lastRow + 1)).")
        }
        let bottom = fillTo ?? lastRow
        guard width > 0, start.column + width <= CellAddress.maxColumns, bottom < CellAddress.maxRows else {
            throw AIToolError("Nothing to write, or the cells would go past the edge of the sheet.")
        }
        guard (bottom - start.row + 1) * width <= writeLimit else {
            throw AIToolError("That is more than \(writeLimit) cells in one call; write in smaller parts.")
        }
        let range = CellRange(start, CellAddress(row: bottom, column: start.column + width - 1))
        try context.change(String(localized: "AI: Write Cells"), { workbook in
            for (rowOffset, row) in inputs.enumerated() {
                for (columnOffset, input) in row.enumerated() {
                    workbook.enter(input, at: CellAddress(row: start.row + rowOffset, column: start.column + columnOffset),
                                   sheet: index)
                }
            }
            if let fillTo {
                workbook.fillDown(row: lastRow, columns: start.column...(start.column + width - 1), through: fillTo, sheet: index)
            }
        }, cells: { workbook in [workbook.sheets[index].id: addresses(in: range)] })
        return .ok(written(range, sheet: context.workbook.sheets[index]), changed: true)
    }

    /// JSON 里的一个值 → 输入：null 清掉；数字就是数字（按最短的写法换成十进制，0.1 就是 0.1）；布尔；
    /// 文字按打字的规矩（= 开头是公式，12% 是百分比……）。
    private static func input(_ value: JSONValue, dateSystem: DateSystem, at place: String) throws -> CellInput {
        switch value {
        case .null: return .clear
        case .bool(let flag): return .value(.bool(flag))
        case .number(let number):
            guard let decimal = DecimalMath.decimal(number) else { throw AIToolError("\(place) is not a finite number.") }
            return .number(decimal, format: nil)
        case .string(let text): return CellInput.parse(text, dateSystem: dateSystem)
        case .array, .object: throw AIToolError("\(place) must be a string, number, boolean or null.")
        }
    }

    /// 写完的结果：范围、公式算出来的值、出错的格子（最多几十个，够 AI 看出哪里不对）。
    private static func written(_ range: CellRange, sheet: Sheet) -> JSONValue {
        var formulas: [JSONValue] = []
        var errors: [JSONValue] = []
        for (address, cell) in sheet.cells.entries(in: range) {
            guard let formula = cell.formula else {
                if case .error(let error) = cell.value, errors.count < 50 {
                    errors.append(["cell": .string(address.a1), "error": .string(error.code)])
                }
                continue
            }
            if case .notRecalculated(let reason) = formula.status, errors.count < 50 {
                errors.append(["cell": .string(address.a1), "error": .string("not calculated: \(reason)")])
            } else if case .error(let error) = cell.value, errors.count < 50 {
                errors.append(["cell": .string(address.a1), "error": .string(error.code), "formula": .string("=" + formula.source)])
            } else if formulas.count < 100 {
                formulas.append(["cell": .string(address.a1), "value": AIFormat.json(cell.value)])
            }
        }
        var payload: [String: JSONValue] = ["sheet": .string(sheet.name), "written": .string(range.a1)]
        if !formulas.isEmpty { payload["formula_values"] = .array(formulas) }
        if !errors.isEmpty { payload["errors"] = .array(errors) }
        return .object(payload)
    }

    private static func addresses(in range: CellRange) -> Set<CellAddress> {
        var result: Set<CellAddress> = []
        for row in range.start.row...range.end.row {
            for column in range.start.column...range.end.column { result.insert(CellAddress(row: row, column: column)) }
        }
        return result
    }

    // MARK: - format_cells

    static func formatCells(_ arguments: AIToolArguments) throws -> AIToolResult {
        let context = try AIWorkbooks.context(arguments)
        let index = try context.sheetIndex(try arguments.requiredString("sheet"))
        try context.requireAISheet(index)
        var change = Workbook.CellStyleChange()
        if let format = try arguments.string("number_format") {
            change.numberFormat = FormatPreset(rawValue: format.lowercased())?.code ?? format
        }
        change.bold = try arguments.bool("bold")
        change.fontColor = try arguments.string("font_color").map { try AIFormat.color($0, key: "font_color") }
        change.fillColor = try arguments.string("fill_color").map { try AIFormat.color($0, key: "fill_color") }
        let width = try arguments.double("column_width")
        let freeze = try arguments.object("freeze")
        let range = try arguments.string("range").map { try AIFormat.range($0).range }
        guard !change.isEmpty || width != nil || freeze != nil else {
            throw AIToolError("Give at least one of number_format, bold, font_color, fill_color, column_width, freeze.")
        }
        if (!change.isEmpty || width != nil), range == nil { throw AIToolError("range is required for those options.") }
        if let range, !change.isEmpty, range.rowCount * range.columnCount > formatLimit {
            throw AIToolError("That range has more than \(formatLimit) cells; format the used part only.")
        }
        if let width, !(0...255).contains(width) { throw AIToolError("column_width must be between 0 and 255.") }
        let frozenRows = try freeze.map { try AIToolArguments(.object($0)).int("rows") ?? 0 }
        let frozenColumns = try freeze.map { try AIToolArguments(.object($0)).int("columns") ?? 0 }
        try context.change(String(localized: "AI: Format Cells"), { workbook in
            if let range, !change.isEmpty { workbook.restyle(range, sheet: index, change) }
            if let range, let width {
                workbook.setColumnWidth(width, columns: range.start.column...range.end.column, sheet: index)
            }
            if let frozenRows, let frozenColumns {
                workbook.freeze(rows: max(frozenRows, 0), columns: max(frozenColumns, 0), sheet: index)
            }
        }, cells: { workbook in
            guard let range, range.rowCount * range.columnCount <= writeLimit else { return [:] }
            return [workbook.sheets[index].id: addresses(in: range)]
        })
        var payload: [String: JSONValue] = ["sheet": .string(context.workbook.sheets[index].name)]
        if let range { payload["range"] = .string(range.a1) }
        return .ok(.object(payload), changed: true)
    }

    // MARK: - edit_sheet

    static func editSheet(_ arguments: AIToolArguments) throws -> AIToolResult {
        let context = try AIWorkbooks.context(arguments)
        let index = try context.sheetIndex(try arguments.requiredString("sheet"))
        try context.requireAISheet(index)
        let newName = try arguments.string("rename")
        let position = try arguments.int("move_to")
        let delete = try arguments.bool("delete") ?? false
        guard newName != nil || position != nil || delete else { throw AIToolError("Give rename, move_to or delete.") }
        do {
            try context.change(String(localized: "AI: Edit Sheet")) { workbook in
                if delete {
                    try workbook.deleteSheet(index)
                    return
                }
                if let newName { try workbook.renameSheet(index, to: newName.trimmingCharacters(in: .whitespaces)) }
                if let position { workbook.moveSheet(from: index, to: position - 1) }
            }
        } catch let SheetEditError.invalidName(problem) {
            throw AIToolError(SheetCommands.message(for: problem))
        } catch SheetEditError.lastVisibleSheet {
            throw AIToolError("That is the last visible sheet; a workbook must keep one.")
        }
        return .ok(["sheets": .array(context.workbook.sheets.map { .string($0.name) })], changed: true)
    }

    // MARK: - undo

    /// 撤 AI 自己的改动。用户在 AI 之后又改过就拒绝：撤一步撤的是栈顶那一步，那是用户的。
    static func undo(_ arguments: AIToolArguments) throws -> AIToolResult {
        let context = try AIWorkbooks.context(arguments)
        let session = context.session
        let ai = AISession.shared
        guard ai.lastChangeIsAI(in: session) else {
            throw AIToolError("The user changed this workbook after your last change, so undo would undo their work. "
                + "Ask the user, or fix things with write_cells.")
        }
        if try arguments.bool("round") == true {
            guard ai.undoRound(in: session) else { throw AIToolError("There is nothing of yours to undo in this round.") }
            ai.noteUndo(in: session, round: true)
            return .ok(["undone": "round", "sheets": .array(context.workbook.sheets.map { .string($0.name) })])
        }
        guard ai.hasUndoableStep(in: session), let manager = session.undoManager, manager.canUndo else {
            throw AIToolError("There is nothing of yours left to undo.")
        }
        let title = manager.undoActionName
        manager.undo()
        ai.noteUndo(in: session)
        return .ok(["undone": .string(title.isEmpty ? "last change" : title)])
    }
}
