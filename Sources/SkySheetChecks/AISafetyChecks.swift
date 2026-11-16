import Foundation
import SkySheetCore
import SkySheetFiles
import SkySheetMCPKit

/// AI 和 MCP 这一块紧急的几处（2026-11-16 排查第 2、3、7、9、10、12 条）：会撤掉用户的活、间接改原始 sheet、
/// 只读的查询写文件、一个调用吃光内存、一个参数让 App 崩溃。工具本身在 App 里，主自检够不着（App 那层的接线在 UI 自检的
/// ai 套件，UI/AISessionChecks）；App 的工具都走这里核对的
/// 入口：整轮撤销问 AIRoundLedger，edit_sheet 和插删行列包在 editSparingOriginalFormulas 里，query 走 SQLQuery 和
/// QueryTables，export_sheet 走 CSVWriter.analysisData，合并带 limit，字符串参数收数字走 JSONValue.numberText。
@MainActor
func aiSafetyChecks() {
    roundUndoChecks()
    originalFormulaChecks()
    readOnlyQueryChecks()
    expansionLimitChecks()
    boundedCheck("jsonNumberText")
}

// MARK: - 第 2 条：整轮撤销

@MainActor
private func roundUndoChecks() {
    group("ai safety: undoing a round refuses once the user changed the workbook") {
        var aiOnly = AIRoundLedger(snapshotRevision: 5)
        aiOnly.noteAIStep(before: 5, after: 6)
        aiOnly.noteAIStep(before: 6, after: 7)
        check(aiOnly.onlyAIChanged(currentRevision: 7), "only the AI changed the workbook: the round can be undone")
        aiOnly.noteAIStep(before: 7, after: 8)
        check(aiOnly.onlyAIChanged(currentRevision: 8), "the AI undoing one of its own steps is still the AI")

        // 排查第 2 条：AI 改 → 用户改 → AI 再改。「最后是 AI 改的」又成立了，快照里却没有用户那一步。
        var interleaved = AIRoundLedger(snapshotRevision: 5)
        interleaved.noteAIStep(before: 5, after: 6)
        interleaved.noteAIStep(before: 7, after: 8)
        check(!interleaved.onlyAIChanged(currentRevision: 8), "the user changed it between two AI changes: refused")
        check(interleaved.userChanged, "the ledger remembers the user's change")

        // 横幅上的按钮：AI 改完，用户又改，后面没有 AI 的改动。
        var afterAI = AIRoundLedger(snapshotRevision: 5)
        afterAI.noteAIStep(before: 5, after: 6)
        check(!afterAI.onlyAIChanged(currentRevision: 7), "the user changed it after the AI's last change: refused")

        // 存了快照、AI 那一下没改成，用户接着改，AI 再改：快照里也没有用户那一步。
        var beforeFirst = AIRoundLedger(snapshotRevision: 5)
        beforeFirst.noteAIStep(before: 6, after: 7)
        check(!beforeFirst.onlyAIChanged(currentRevision: 7), "the user changed it before the AI's first change landed: refused")
    }
}

// MARK: - 第 3 条：AI 改自己的 sheet，不许连带改原始 sheet 的公式

@MainActor
private func originalFormulaChecks() {
    group("ai safety: AI sheet edits never rewrite formulas in original sheets") {
        let ai = SheetRole.ai(AIAuthorship(created: AIAuthorship.Mark(.ai(client: "Claude Code", model: nil),
                                                                      date: Date(timeIntervalSince1970: 0))))
        let original = makeSheet("Orig Data", id: 1, ["A1": "=R!A1", "B1": "=SUM(R!A1:A3)", "C1": "=1+1"])
        var result = makeSheet("R", id: 2, ["A1": "7", "A2": "8", "A3": "9", "A10": "1"])
        result.role = ai
        var mine = makeSheet("Mine", id: 3, ["A1": "=R!A10"])
        mine.role = ai
        var free = makeSheet("Free", id: 4, ["A1": "1"])
        free.role = ai
        let workbook = Workbook(sheets: [original, result, mine, free])
        let both = ["'Orig Data'!A1", "'Orig Data'!B1"]

        @MainActor func refused(_ what: String, _ edit: (inout Workbook) throws -> Void) -> [String]? {
            var copy = workbook
            do {
                try copy.editSparingOriginalFormulas(edit)
            } catch let error as OriginalFormulasWouldChange {
                check(copy == workbook, "\(what): refused, and nothing changed")
                return error.cells
            } catch {
                fail("\(what): unexpected \(error)")
                return nil
            }
            let formulas = ["A1", "B1"].map { copy.sheets[0].cells[CellAddress(a1: $0)!]?.formula?.source ?? "-" }
            fail("\(what): went through; Orig Data now has \(formulas)")
            return nil
        }

        @MainActor func allowed(_ what: String, _ edit: (inout Workbook) throws -> Void) -> Workbook? {
            var copy = workbook
            do {
                try copy.editSparingOriginalFormulas(edit)
            } catch {
                fail("\(what): refused with \(error)")
                return nil
            }
            var plain = workbook
            try? edit(&plain)
            check(copy == plain, "\(what): same result as doing it directly")
            checkEqual(copy.sheets[0], workbook.sheets[0], "\(what): the original sheet is untouched")
            return copy
        }

        // 排查第 3 条的原例：删掉被引用的 AI 的 sheet。
        checkEqual(refused("delete R") { try $0.deleteSheet(1) }, both, "deleting R lists the cells that refer to it")
        checkEqual(refused("rename R") { try $0.renameSheet(1, to: "S") }, both, "renaming R")
        checkEqual(refused("insert a row above R!A1") { _ = try $0.shiftLines(.insert(1, at: 0, .rows), sheet: 1) }, both,
                   "inserting rows moves what the originals refer to")
        checkEqual(refused("delete R row 2") { _ = try $0.shiftLines(.delete(1...1, .rows), sheet: 1) }, ["'Orig Data'!B1"],
                   "deleting a row inside SUM(R!A1:A3) shrinks it")
        checkEqual(refused("insert a column in R") { _ = try $0.shiftLines(.insert(1, at: 0, .columns), sheet: 1) }, both,
                   "inserting a column")

        // 原始 sheet 不指着的地方照常：AI 自己的公式跟着改。
        if let inserted = allowed("insert rows below what the originals use", { _ = try $0.shiftLines(.insert(2, at: 4, .rows), sheet: 1) }) {
            checkEqual(inserted.sheets[2].cells[CellAddress(a1: "A1")!]?.formula?.source, "R!A12", "the AI sheet's formula follows")
        }
        if let deleted = allowed("delete R row 10", { _ = try $0.shiftLines(.delete(9...9, .rows), sheet: 1) }) {
            check(deleted.sheets[2].cells[CellAddress(a1: "A1")!]?.formula?.source.contains("#REF!") == true,
                  "the AI sheet's own reference becomes #REF!")
        }
        _ = allowed("delete a sheet nothing original refers to") { try $0.deleteSheet(3) }
        _ = allowed("rename a sheet nothing original refers to") { try $0.renameSheet(3, to: "Spare") }
        _ = allowed("move R") { $0.moveSheet(from: 1, to: 3) }
    }
}

// MARK: - 第 7 条：只读的 query 不许开文件、不许写

@MainActor
private func readOnlyQueryChecks() {
    group("ai safety: query only reads and creates no files") {
        let directory = try makeTemporaryDirectory()
        let sheet = makeSheet("S", id: 1, ["A1": "Name", "B1": "Amount", "A2": "a", "B2": "1", "A3": "b", "B3": "2"])
        let tables = QueryTables.tables(for: Workbook(sheets: [sheet]))
        func path(_ name: String) -> String {
            directory.appendingPathComponent(name).path.replacingOccurrences(of: "'", with: "''")
        }
        @MainActor func refused(_ sql: String) {
            do {
                _ = try SQLQuery.run(sql, tables: tables)
                fail("accepted: \(sql)")
            } catch {
                check(error.message.contains("only SELECT"), "\(sql) → \(error.message)")
            }
        }
        // 排查第 7 条的原例：sqlite3_stmt_readonly 放行 ATTACH，它在磁盘上新建了一个空的数据库文件。
        refused("ATTACH DATABASE '\(path("attached.db"))' AS x")
        refused("ATTACH ':memory:' AS m")
        refused("DETACH DATABASE m")
        refused("VACUUM INTO '\(path("vacuumed.db"))'")
        refused("PRAGMA query_only = 0")
        refused("BEGIN")
        refused(#"CREATE TEMP TABLE t(x)"#)
        let created = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? ["?"]
        checkEqual(created, [], "no file appeared on disk")

        checkEqual(try SQLQuery.run(#"SELECT sum("Amount") FROM "S""#, tables: tables).rows, [[.real(3)]], "reading still works")
        checkEqual(try SQLQuery.run("WITH t(x) AS (SELECT 2) SELECT x * 3 FROM t", tables: tables).rows, [[.integer(6)]],
                   "a WITH query still works")
        checkEqual(try SQLQuery.run("SELECT name FROM pragma_table_info('S')", tables: tables).rows,
                   [[.text("_row")], [.text("Name")], [.text("Amount")]], "reading a table's columns still works")
    }
}

// MARK: - 第 9、10 条：AI 给的区域先按面积查，再展开

@MainActor
private func expansionLimitChecks() {
    group("ai safety: huge ranges are refused by area before anything is expanded") {
        var bold = Workbook.CellStyleChange()
        bold.bold = true
        var workbook = Workbook(sheets: [makeSheet("R", id: 1, ["A1": "x"]), Sheet(id: 2, name: "Empty"),
                                         makeSheet("Sparse", id: 3, ["A1": "1", "XFD1048576": "2"])])
        workbook.restyle(CellRange(a1: "A1")!, sheet: 0, bold)
        let start = workbook

        // 先用小上限、刚超过一点的区域确认真的按面积拦：没有这道检查时这几块会照常展开（都很小）。
        var merged = workbook
        var mergeRefused = false
        do throws(MergeError) {
            try merged.merge(CellRange(a1: "A1:J20")!, sheet: 0, limit: 100)
            fail("200 cells were merged under a limit of 100")
        } catch {
            checkEqual(error, .tooLarge(limit: 100), "merging more than the limit")
            mergeRefused = true
        }
        check(merged == start, "a refused merge changes nothing")

        var tablesRefused = false
        do throws(TooManyCells) {
            _ = try QueryTables.tables(for: workbook, extra: [("T", 0, CellRange(a1: "A1:J6")!), ("U", 0, CellRange(a1: "A1:J6")!)],
                                       limit: 100)
            fail("120 cells were loaded under a limit of 100")
        } catch {
            checkEqual(error, TooManyCells(cells: 120, limit: 100), "named ranges count together")
            tablesRefused = true
        }

        var exportRefused = false
        do throws(TooManyCells) {
            _ = try CSVWriter.analysisData(workbook.sheets[0], range: CellRange(a1: "A1:J20")!, styles: workbook.styles,
                                           dateSystem: workbook.dateSystem, limit: 100)
            fail("200 cells were exported under a limit of 100")
        } catch {
            checkEqual(error, TooManyCells(cells: 200, limit: 100), "exporting more than the limit")
            exportRefused = true
        }

        // 排查第 9、10 条的原例，都是一百多亿格：只在上面确认拦得住以后才跑（拦不住会真的去展开）。
        guard mergeRefused, tablesRefused, exportRefused else { return }
        let everything = CellRange(CellAddress(row: 0, column: 0),
                                   CellAddress(row: CellAddress.maxRows - 1, column: CellAddress.maxColumns - 1))
        let clock = Date()
        do throws(MergeError) {
            try merged.merge(CellRange(a1: "A1:XFC1048575")!, sheet: 0, limit: 50_000)
            fail("A1:XFC1048575 was merged")
        } catch {
            checkEqual(error, .tooLarge(limit: 50_000), "format_cells merge of A1:XFC1048575")
        }
        check(merged == start, "no cells made, no merge recorded")
        do throws(TooManyCells) {
            _ = try QueryTables.tables(for: workbook, extra: [("T", 1, everything)])
            fail("A:XFD of an empty sheet was loaded")
        } catch {
            checkEqual(error, TooManyCells(cells: 17_179_869_184, limit: ExpansionLimit.cells), "query tables {T: Empty!A:XFD}")
        }
        let sparse = workbook.sheets[2]
        let exported = CellRange(CellAddress(row: 0, column: 0), sparse.contentRange!.end)
        do throws(TooManyCells) {
            _ = try CSVWriter.analysisData(sparse, range: exported, styles: workbook.styles, dateSystem: workbook.dateSystem)
            fail("a sheet with A1 and XFD1048576 was exported")
        } catch {
            checkEqual(error, TooManyCells(cells: 17_179_869_184, limit: ExpansionLimit.cells), "export_sheet of a sparse sheet")
        }
        check(Date().timeIntervalSince(clock) < 1, "all three refused before touching the cells")

        // 上限以内照常。
        try merged.merge(CellRange(a1: "A1:J10")!, sheet: 0, limit: 100)
        checkEqual(merged.sheets[0].merges, [CellRange(a1: "A1:J10")!], "a merge within the limit")
        let tables = try QueryTables.tables(for: workbook, extra: [("T", 0, CellRange(a1: "A1:B3")!)])
        checkEqual(tables.first { $0.name == "T" }?.rows.count, 2, "a named range within the limit")
        let csv = try CSVWriter.analysisData(workbook.sheets[0], range: CellRange(a1: "A1:B2")!, styles: workbook.styles,
                                             dateSystem: workbook.dateSystem)
        checkEqual(String(decoding: csv, as: UTF8.self), "x,\n,\n", "an export within the limit")
    }
}

// MARK: - 第 12 条：字符串参数收到超大数字（子进程里跑：以前是直接崩溃）

@MainActor
func jsonNumberTextChecks() {
    group("ai safety: jsonNumberText") {
        for huge in [1e100, -1e100, 9_223_372_036_854_775_808.0, 1.7976931348623157e308] {
            checkEqual(JSONValue.number(huge).numberText, nil, "\(huge) has no usable text: a parameter error, not a crash")
        }
        checkEqual(try JSONValue.decode(Data(#"{"sheet":1e100}"#.utf8))["sheet"]?.numberText, nil,
                   "describe_sheet({\"sheet\":1e100}) as the App receives it")
        // 以前能用的照旧。
        checkEqual(JSONValue.number(2024).numberText, "2024", "a whole number reads as digits")
        checkEqual(JSONValue.number(-0.0).numberText, "0", "minus zero")
        checkEqual(JSONValue.number(1.5).numberText, "1.5", "a fraction")
        checkEqual(JSONValue.number(1e18).numberText, "1000000000000000000", "a large whole number inside Int")
        checkEqual(JSONValue.number(-9_223_372_036_854_775_808.0).numberText, "-9223372036854775808", "Int.min")
        checkEqual(JSONValue.string("x").numberText, nil, "not a number")
    }
}
