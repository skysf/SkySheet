import Foundation
import SkySheetCore
import SkySheetFiles
import SkySheetMCPKit

// MARK: - edit_rows_columns：整行整列的插删、宽高、自动适应、隐藏、冻结（2026-10-14 加，和界面上的同一组功能）
//
// 和别的写入工具一样只认 AI 的 sheet，一个调用一步撤销。插删只在安全的表上做（StructureLock，设计第 11 条）：
// 不安全的说清楚为什么、让 AI 复制一份改副本（副本不带图片这些东西）。

@MainActor
enum AIRowColumnTools {
    /// 改行高、隐藏时一次最多这么多行：每一行单独记，一百多万行太多。
    static let rowLimit = 100_000

    static func edit(_ arguments: AIToolArguments) throws -> AIToolResult {
        let context = try AIWorkbooks.context(arguments)
        let index = try context.sheetIndex(try arguments.requiredString("sheet"))
        try context.requireAISheet(index)
        let rowsText = try arguments.string("rows")
        let columnsText = try arguments.string("columns")
        guard (rowsText == nil) != (columnsText == nil) else {
            throw AIToolError("Give rows (like \"3:5\") or columns (like \"B:D\"), one of them.")
        }
        let axis: SheetAxis = rowsText != nil ? .rows : .columns
        let lines = try AIFormat.lines(axis, rowsText ?? columnsText ?? "")
        let insert = try arguments.bool("insert") ?? false
        let delete = try arguments.bool("delete") ?? false
        let width = try arguments.double("width")
        let height = try arguments.double("height")
        let autofit = try arguments.bool("autofit") ?? false
        let hidden = try arguments.bool("hidden")
        let freeze = try arguments.bool("freeze")
        let others = width != nil || height != nil || autofit || hidden != nil || freeze != nil
        if insert || delete {
            guard !(insert && delete) else { throw AIToolError("Give insert or delete, not both.") }
            guard !others else {
                throw AIToolError("insert and delete can't be combined with other options; make a second call for those.")
            }
            return try shift(insert ? .insert(lines.count, at: lines.lowerBound, axis) : .delete(lines, axis),
                             context: context, sheet: index)
        }
        guard others else { throw AIToolError("Say what to do: insert, delete, width, height, autofit, hidden or freeze.") }
        if width != nil, axis == .rows { throw AIToolError("width is for columns; rows have height.") }
        if height != nil, axis == .columns { throw AIToolError("height is for rows; columns have width.") }
        if autofit, width != nil || height != nil { throw AIToolError("Give a size or autofit, not both.") }
        if let width, !(width > 0 && width <= 255) {
            throw AIToolError("width must be more than 0 and at most 255 characters; hidden=true hides columns.")
        }
        if let height, !(height > 0 && height <= 409) {
            throw AIToolError("height must be more than 0 and at most 409 points; hidden=true hides rows.")
        }
        if freeze == true, lines.lowerBound != 0 {
            throw AIToolError(axis == .rows ? "Frozen rows always start at row 1: give rows \"1:N\" to keep the top N rows in view."
                                            : "Frozen columns always start at column A: give columns \"A:X\".")
        }
        if axis == .rows, height != nil || hidden != nil || autofit, lines.count > rowLimit {
            throw AIToolError("That is more than \(rowLimit) rows in one call; give fewer rows.")
        }
        let fonts = FontBook()
        let fitted: [Int: Double?] = !autofit ? [:] : axis == .columns
            ? ContentFit.widths(lines, sheet: index, in: context.session, fonts: fonts)
            : ContentFit.heights(lines, sheet: index, in: context.session, fonts: fonts)
        try context.change(String(localized: "AI: Edit Rows and Columns")) { workbook in
            if let width { workbook.setColumnWidth(width, columns: lines, sheet: index) }
            if let height { workbook.setRowHeight(height, rows: lines, sheet: index) }
            for (line, size) in fitted {
                switch axis {
                case .columns: workbook.setColumnWidth(size, columns: line...line, sheet: index)
                case .rows: workbook.setRowHeight(size, rows: line...line, sheet: index)
                }
            }
            if let hidden { workbook.setHidden(hidden, axis, lines, sheet: index) }
            if let freeze {
                let frozen = workbook.sheets[index].frozen ?? FrozenPanes(rows: 0, columns: 0)
                let count = freeze ? lines.upperBound + 1 : 0
                workbook.freeze(rows: axis == .rows ? count : frozen.rows, columns: axis == .columns ? count : frozen.columns,
                                sheet: index)
            }
        }
        let sheet = context.workbook.sheets[index]
        var payload: [String: JSONValue] = ["sheet": .string(sheet.name),
                                            (axis == .rows ? "rows" : "columns"): .string(AIFormat.label(axis, lines))]
        if autofit {
            // 自动适应以后每一行（列）多大；null 是回到了默认大小（那一行没有内容）。
            payload["sizes"] = .object(Dictionary(uniqueKeysWithValues: fitted.map { line, size in
                (AIFormat.label(axis, line...line), size.map { .number(($0 * 100).rounded() / 100) } ?? .null)
            }))
        }
        if freeze != nil {
            payload["frozen"] = ["rows": .number(Double(sheet.frozen?.rows ?? 0)),
                                 "columns": .number(Double(sheet.frozen?.columns ?? 0))]
        }
        return .ok(.object(payload), changed: true)
    }

    /// 插删。先问这张表能不能插删；公式跟着改，回报改了几个、哪些变成了 #REF!。
    private static func shift(_ shift: LineShift, context: AIContext, sheet index: Int) throws -> AIToolResult {
        let sheet = context.workbook.sheets[index]
        if let lock = context.document.structureLock(forSheet: sheet.id) {
            throw AIToolError("""
                Rows and columns can't be inserted or deleted in \(sheet.name): \(lock.reason), which SkySheet keeps but \
                can't move. Copy it with add_sheet copy_from (the copy leaves those out) and change the copy.
                """)
        }
        var report = StructureEditReport()
        let name = shift.kind == .insert ? String(localized: "AI: Insert Rows or Columns")
                                         : String(localized: "AI: Delete Rows or Columns")
        do {
            try context.change(name) { workbook in report = try workbook.shiftLines(shift, sheet: index) }
        } catch let error as StructureEditError {
            throw AIToolError(message(error))
        }
        context.session.remapHighlights(after: shift, sheetID: sheet.id)
        let workbook = context.workbook
        var payload: [String: JSONValue] = [
            "sheet": .string(workbook.sheets[index].name),
            (shift.kind == .insert ? "inserted" : "deleted"): .string(AIFormat.label(shift.axis, shift.lines)),
            "formulas_updated": .number(Double(report.updatedFormulas)),
            "used_range": AIWorkbookTools.usedRange(workbook.sheets[index]).map { .string($0.a1) } ?? .null,
        ]
        if !report.brokenFormulas.isEmpty {
            payload["ref_errors"] = .array(report.brokenFormulas.map { location in
                let sheetName = FormulaRewriter.quotedSheetName(workbook.sheets[location.sheet].name)
                return .string("\(sheetName)!\(location.address.a1)")
            })
        }
        return .ok(.object(payload), changed: true)
    }

    private static func message(_ error: StructureEditError) -> String {
        switch error {
        case .wouldPushContentOffSheet:
            "There is no room: inserting would push cells with content off the end of the sheet."
        case .unreadableFormula(let sheet, let cell):
            "SkySheet can't read the formula in \(sheet)!\(cell.a1), so it couldn't keep its references right. Nothing changed."
        case .unreadableName(let name):
            "SkySheet can't read the defined name \(name), so it couldn't keep its references right. Nothing changed."
        case .splitsArrayFormula(let range):
            "That would split the array formula in \(range.a1). Nothing changed."
        }
    }
}
