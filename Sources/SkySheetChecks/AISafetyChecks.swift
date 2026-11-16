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

