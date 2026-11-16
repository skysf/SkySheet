import Foundation
import SkySheetCore
import SkySheetFiles
import SkySheetMCPKit

/// AI 和 MCP 这一块紧急的几处（2026-11-16 排查第 2、3、7、9、10、12 条）：会撤掉用户的活、间接改原始 sheet、
/// 只读的查询写文件、一个调用吃光内存、一个参数让 App 崩溃。工具本身在 App 里，自检够不着；App 的工具都走这里核对的
/// 入口：整轮撤销问 AIRoundLedger，edit_sheet 和插删行列包在 editSparingOriginalFormulas 里，query 走 SQLQuery 和
/// QueryTables，export_sheet 走 CSVWriter.analysisData，合并带 limit，字符串参数收数字走 JSONValue.numberText。
@MainActor
func aiSafetyChecks() {
    roundUndoChecks()
    originalFormulaChecks()
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

