import Foundation

// MARK: - 看和取的工具（不改工作簿）：get_status、open_file、describe_sheet、read_range、query、evaluate、export_sheet、
// show、save_copy（设计 9.2 节）。open_file 和 save_copy 不改数据但会开窗口、写新文件，所以不标只读。

enum MCPReadTools {
    static func definition(for tool: MCPToolName) -> MCPToolDefinition {
        switch tool {
        case .getStatus:
            return MCPToolDefinition(
                .getStatus, title: "Get status",
                description: """
                    Lists the workbooks open in SkySheet. For each: path, whether it has unsaved changes, and its sheets \
                    with their role (original data, read-only to you, or an AI sheet you may edit, with who wrote it) \
                    and used range; plus the sheet the user is looking at and their selection ("this block" or \
                    "these numbers" usually means the selection). Call it first. If nothing is open, ask the user \
                    which file to use, then call open_file.
                    """,
                readOnly: true)
        case .openFile:
            return MCPToolDefinition(
                .openFile, title: "Open file",
                description: """
                    Opens an .xlsx, .csv or .tsv file in SkySheet and makes it the current workbook. A window appears \
                    but SkySheet does not take keyboard focus. Only open paths the user gave you or tools returned. \
                    Opening a file that is already open just makes it current. Returns the same summary as get_status \
                    for that workbook.
                    """,
                input: MCPSchema.object(["path": MCPSchema.string("Absolute path, or starting with ~.")],
                                        required: ["path"]))
        case .describeSheet:
            return MCPToolDefinition(
                .describeSheet, title: "Describe sheet",
                description: """
                    Describes one sheet so you know where things are before reading: its used range; each table \
                    block (a header row and the rows under it, separated by empty rows) with the table name to use in \
                    query, and for each column its header, type (number, date, text, mixed), number format, count, \
                    a few sample values, and sum, min and max for numbers; merged cells; frozen panes; how many \
                    formulas; and cells SkySheet could not recalculate (they keep the value saved in the file).
                    """,
                input: MCPSchema.object(["sheet": MCPSchema.sheet, "workbook": MCPSchema.workbook], required: ["sheet"]),
                readOnly: true)
        case .readRange:
            return MCPToolDefinition(
                .readRange, title: "Read range",
                description: """
                    Reads a block of cells as rows. values hold full precision: numbers as numbers, dates as \
                    spreadsheet serial numbers, errors such as "#DIV/0!" as strings, empty cells as null. \
                    include=["text"] adds what each cell shows (formatted, e.g. a currency amount or a date) and \
                    include=["formulas"] adds formula text (null where there is none). At most 2,000 cells per call: \
                    for more, use query or export_sheet.
                    """,
                input: MCPSchema.object([
                    "range": MCPSchema.string("A1 range such as A1:K11, or with the sheet: Loan!A1:K11."),
                    "sheet": MCPSchema.string("Sheet name, if range does not include it."),
                    "include": MCPSchema.array(of: MCPSchema.string("Extra", oneOf: MCPVocabulary.readExtras),
                                               "Extras to return besides values."),
                    "workbook": MCPSchema.workbook,
                ], required: ["range"]),
                readOnly: true)
        case .query:
            return MCPToolDefinition(
                .query, title: "Query with SQL",
                description: """
                    Runs one read-only SQL SELECT (SQLite) over the table blocks of the workbook. Table and column \
                    names come from describe_sheet; put them in double quotes (any language is fine). Every table \
                    also has a _row column: the sheet row of that record, so you can point formulas at it. Dates are \
                    text 'YYYY-MM-DD'; numbers are floating point, fine for sums and comparisons. For amounts that \
                    must be exact, write formulas instead. tables can name extra ranges, each read with its first \
                    row as the header. Returns at most 500 rows.
                    """,
                input: MCPSchema.object([
                    "sql": MCPSchema.string("One SELECT statement."),
                    "tables": MCPSchema.object([:], description:
                        "Optional extra tables: name -> range whose first row is the header, e.g. {\"plans\": \"Loan!A13:J26\"}."),
                    "workbook": MCPSchema.workbook,
                ], required: ["sql"]),
                readOnly: true)
        case .evaluate:
            return MCPToolDefinition(
                .evaluate, title: "Evaluate formula",
                description: """
                    Calculates one formula with SkySheet's engine without writing it anywhere, e.g. \
                    =PMT(3.1%/12,360,-1000000) for a monthly payment, or =RATE(36,-1047.40,36144.81)*12. \
                    References such as B2 or Loan!B2 read the workbook; sheet sets where plain references point \
                    (default: the current sheet). Returns the value and how it displays. Use it to try a formula \
                    before writing it.
                    """,
                input: MCPSchema.object([
                    "formula": MCPSchema.string("The formula, with or without the leading =."),
                    "sheet": MCPSchema.sheet,
                    "workbook": MCPSchema.workbook,
                ], required: ["formula"]),
                readOnly: true)
        case .exportSheet:
            return MCPToolDefinition(
                .exportSheet, title: "Export sheet as CSV",
                description: """
                    Writes a sheet, or a range of it, to a UTF-8 CSV file in SkySheet's cache folder and returns its \
                    path, for Python or pandas. Numbers are written raw (no thousands separators; percents as \
                    fractions), dates as YYYY-MM-DD, formulas as their values; the first row is written as it is \
                    (usually the header). Bring results back with add_sheet from_csv or write_cells. Never change \
                    the user's own files with other programs.
                    """,
                input: MCPSchema.object([
                    "sheet": MCPSchema.sheet,
                    "range": MCPSchema.string("Optional A1 range; default: the sheet's used range."),
                    "workbook": MCPSchema.workbook,
                ], required: ["sheet"]),
                readOnly: true)
        case .show:
            return MCPToolDefinition(
                .show, title: "Show the user",
                description: """
                    Points the user at something: switches the window to the sheet, selects the range, and brings \
                    that window to the front without taking keyboard focus from the app the user is typing in. \
                    Changes no data. Use it at the end to show your results.
                    """,
                input: MCPSchema.object([
                    "sheet": MCPSchema.sheet,
                    "range": MCPSchema.string("Optional A1 range to select."),
                    "workbook": MCPSchema.workbook,
                ], required: ["sheet"]),
                readOnly: true)
        case .saveCopy:
            return MCPToolDefinition(
                .saveCopy, title: "Save a copy",
                description: """
                    Saves the workbook to a new file: .xlsx keeps every sheet; .csv holds one sheet (sheet, or the \
                    one the user is looking at). The path must not exist yet: SkySheet never overwrites files for \
                    AI. The open window keeps working on the user's file, which only changes when they press Cmd+S.
                    """,
                input: MCPSchema.object([
                    "path": MCPSchema.string("New file path ending in .xlsx or .csv."),
                    "sheet": MCPSchema.string("For .csv: which sheet to save."),
                    "workbook": MCPSchema.workbook,
                ], required: ["path"]))
        default:
            preconditionFailure("\(tool) is not a read tool")
        }
    }
}
