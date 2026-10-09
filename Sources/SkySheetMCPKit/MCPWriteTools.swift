import Foundation

// MARK: - 改东西的工具：add_sheet、write_cells、format_cells、edit_sheet、undo（设计 9.2、9.3 节）。
// 只认 AI 的 sheet：原始 sheet 一律拒绝，拒绝的话里直接说「用 add_sheet copy_from 复制一份再改」（App 那头）。

enum MCPWriteTools {
    static func definition(for tool: MCPToolName) -> MCPToolDefinition {
        switch tool {
        case .addSheet:
            return MCPToolDefinition(
                .addSheet, title: "Add AI sheet",
                description: """
                    Creates a new AI sheet: the only kind of sheet you can write to. Empty by default; \
                    copy_from=<sheet> copies a sheet (values, formulas, formats) so you can change its data without \
                    touching the original; from_csv=<path> imports a CSV file, for example pandas output. Set model \
                    to your model id (e.g. claude-opus-5-5): the purple sheet tab shows who wrote it. The name must \
                    be new and returns as used. The sheet goes after copy_from's sheet, otherwise at the end.
                    """,
                input: MCPSchema.object([
                    "name": MCPSchema.string("Name of the new sheet (up to 31 characters, none of : \\ / ? * [ ])."),
                    "copy_from": MCPSchema.string("Sheet to copy."),
                    "from_csv": MCPSchema.string("Path of a CSV file to import."),
                    "model": MCPSchema.string("Your model id, shown as the author of the sheet."),
                    "workbook": MCPSchema.workbook,
                ], required: ["name"]))
        case .writeCells:
            return MCPToolDefinition(
                .writeCells, title: "Write cells",
                description: """
                    Writes values and formulas into an AI sheet (original sheets are read-only: add_sheet copy_from \
                    first). Give start, the top-left cell, and rows, a list of rows of values. A string starting with \
                    = is a formula; prefer formulas that reference the original cells, e.g. \
                    =RATE(Loan!C5,-Loan!F5,Loan!B5)*12, so the user can trace every number. Other strings are read \
                    like typing ("12%", "2025-12-01"; "'00123" stays text); numbers are numbers; null clears a cell. \
                    fill_down_to=<row> copies the last written row down to that row with references shifted, like \
                    dragging the fill handle. Returns the written range, the values the formulas produced, and the \
                    cells that ended up with errors.
                    """,
                input: MCPSchema.object([
                    "sheet": MCPSchema.sheet,
                    "start": MCPSchema.string("Top-left cell, e.g. A1."),
                    "rows": MCPSchema.array(of: ["type": "array", "items": [:]],
                                            "Rows of values: strings, numbers, booleans or null.", minItems: 1),
                    "fill_down_to": MCPSchema.integer("Row number to fill the last row down to.", minimum: 1),
                    "workbook": MCPSchema.workbook,
                ], required: ["sheet", "start", "rows"]))
        case .formatCells:
            return MCPToolDefinition(
                .formatCells, title: "Format cells",
                description: """
                    Formats cells of an AI sheet. Only the options you give change. number_format: a preset (cny and \
                    cny_int for yuan amounts, wan and wan_exact for amounts in units of 10,000, percent, date, \
                    date_cn) or an Excel format code such as 0.00%. bold; font_color and fill_color as hex like \
                    #C00000; column_width in characters for the range's columns; freeze keeps the top rows and left \
                    columns in view, e.g. {"rows": 1, "columns": 1} ({"rows": 0, "columns": 0} unfreezes).
                    """,
                input: MCPSchema.object([
                    "sheet": MCPSchema.sheet,
                    "range": MCPSchema.string("A1 range to format (not needed for freeze alone)."),
                    "number_format": MCPSchema.string("Preset (\(MCPVocabulary.numberFormatPresets.joined(separator: ", "))) or format code."),
                    "bold": MCPSchema.boolean("Bold text on or off."),
                    "font_color": MCPSchema.string("Text color, hex such as #C00000."),
                    "fill_color": MCPSchema.string("Background color, hex such as #FFF2CC."),
                    "column_width": MCPSchema.number("Width of the range's columns in characters.", minimum: 0, maximum: 255),
                    "freeze": MCPSchema.object(["rows": MCPSchema.integer("Rows to freeze.", minimum: 0),
                                                "columns": MCPSchema.integer("Columns to freeze.", minimum: 0)],
                                               description: "Frozen panes of the sheet."),
                    "workbook": MCPSchema.workbook,
                ], required: ["sheet"]))
        case .editSheet:
            return MCPToolDefinition(
                .editSheet, title: "Rename, move or delete AI sheet",
                description: """
                    Renames, moves or deletes an AI sheet; original sheets cannot be changed. Formulas that refer to \
                    a renamed sheet follow the new name; references to a deleted sheet become #REF!. Like every \
                    change, it can be undone.
                    """,
                input: MCPSchema.object([
                    "sheet": MCPSchema.sheet,
                    "rename": MCPSchema.string("New name."),
                    "move_to": MCPSchema.integer("New position among the sheet tabs, starting at 1.", minimum: 1),
                    "delete": MCPSchema.boolean("Delete the sheet."),
                    "workbook": MCPSchema.workbook,
                ], required: ["sheet"]),
                destructive: true)
        case .undo:
            return MCPToolDefinition(
                .undo, title: "Undo",
                description: """
                    Undoes your last change, or with round=true everything since your current round of changes \
                    began, as one step (the user can redo it with Cmd+Shift+Z). Refuses when the user changed the \
                    workbook after you, so their work is never undone by mistake.
                    """,
                input: MCPSchema.object([
                    "round": MCPSchema.boolean("Undo the whole round instead of the last change."),
                    "workbook": MCPSchema.workbook,
                ]))
        default:
            preconditionFailure("\(tool) is not a write tool")
        }
    }
}
