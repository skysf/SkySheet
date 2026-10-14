import Foundation

// MARK: - 改东西的工具：add_sheet、write_cells、format_cells、edit_rows_columns、edit_sheet、undo（设计 9.2、9.3 节）。
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
                    Formats cells of an AI sheet. Only the options you give change. range is an A1 range; whole \
                    columns (C:E) or rows (3:5) format the cells in use, so write the cells first. number_format: \
                    a preset (general; number for 1,234.56; cny and cny_int for yuan amounts; wan and wan_exact for \
                    amounts in units of 10,000; percent; date; date_cn) or an Excel format code such as 0.00%. \
                    bold, italic; font_color and fill_color as hex like #C00000 (font_color "auto" goes back to the \
                    default color, fill_color "none" removes the fill); align and vertical_align; wrap wraps long \
                    text inside the cell. merge=true merges the range into one cell, keeping the top-left value \
                    (refused while other cells in it have content: clear them first); merge=false unmerges merged \
                    cells in the range. Column widths, row heights, hiding and freezing are in edit_rows_columns.
                    """,
                input: MCPSchema.object([
                    "sheet": MCPSchema.sheet,
                    "range": MCPSchema.string("A1 range such as B2:D9, or whole columns (C:E) or rows (3:5)."),
                    "number_format": MCPSchema.string("Preset (\(MCPVocabulary.numberFormatPresets.joined(separator: ", "))) or format code."),
                    "bold": MCPSchema.boolean("Bold text on or off."),
                    "italic": MCPSchema.boolean("Italic text on or off."),
                    "font_color": MCPSchema.string("Text color, hex such as #C00000, or auto."),
                    "fill_color": MCPSchema.string("Background color, hex such as #FFF2CC, or none."),
                    "align": MCPSchema.string("Horizontal alignment; general puts numbers right and text left.",
                                              oneOf: MCPVocabulary.horizontalAlignments),
                    "vertical_align": MCPSchema.string("Vertical alignment.", oneOf: MCPVocabulary.verticalAlignments),
                    "wrap": MCPSchema.boolean("Wrap long text onto more lines inside the cell."),
                    "merge": MCPSchema.boolean("true merges the range into one cell; false unmerges merged cells in it."),
                    "workbook": MCPSchema.workbook,
                ], required: ["sheet", "range"]))
        case .editRowsColumns:
            return MCPToolDefinition(
                .editRowsColumns, title: "Edit rows and columns",
                description: """
                    Changes whole rows or columns of an AI sheet. Give rows ("3" or "3:5") or columns ("C" or \
                    "B:D") and what to do.
                    insert=true puts that many new empty rows (columns) there, pushing the existing ones down \
                    (right); delete=true removes them and moves the rest up (left). Formulas anywhere that point at \
                    moved cells follow them; references to deleted cells become #REF!. insert and delete are refused \
                    on sheets with pictures, charts, comments, conditional formatting, data validation or similar, \
                    which SkySheet keeps but cannot move (describe_sheet says so); they cannot be combined with the \
                    other options.
                    width (columns, in characters, up to 255) or height (rows, in points, up to 409) sets the size; \
                    autofit=true sizes them to their content. hidden=true hides them, hidden=false shows them again. \
                    freeze=true keeps them in view while scrolling: they must start at row 1 or column A (rows "1" \
                    freezes a header row); freeze=false unfreezes the rows (or columns).
                    Returns what changed; for insert and delete, how many formulas were updated and which ones now \
                    show #REF!.
                    """,
                input: MCPSchema.object([
                    "sheet": MCPSchema.sheet,
                    "rows": MCPSchema.string("Row numbers, like 3 or 3:5."),
                    "columns": MCPSchema.string("Column letters, like C or B:D."),
                    "insert": MCPSchema.boolean("Insert that many new empty rows or columns at this place."),
                    "delete": MCPSchema.boolean("Delete these rows or columns."),
                    "width": MCPSchema.number("Column width in characters.", minimum: 0, maximum: 255),
                    "height": MCPSchema.number("Row height in points.", minimum: 0, maximum: 409),
                    "autofit": MCPSchema.boolean("Size to the content."),
                    "hidden": MCPSchema.boolean("true hides, false shows them again."),
                    "freeze": MCPSchema.boolean("true freezes these top rows or left columns; false unfreezes."),
                    "workbook": MCPSchema.workbook,
                ], required: ["sheet"]),
                destructive: true)
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
