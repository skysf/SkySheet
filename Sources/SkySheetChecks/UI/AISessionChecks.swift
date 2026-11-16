import AppKit
import SkySheetCore
import SkySheetMCPKit

/// App 这一层的接线（2026-11-16 排查第 2、12 条）：AISafetyChecks 核对的是 Core / MCPKit 里的入口，这里核对 App 真的
/// 走了它们 —— AI 的 undo round=true 和横幅上的按钮都调 AISession.undoRound，字符串参数都过 AIToolArguments.string。
/// 改动照 AIContext.change 的顺序走（beginChange → apply → noteChange），用户的改动是普通的 apply。
@MainActor
func aiSessionChecks() {
    let role = SheetRole.ai(AIAuthorship(created: AIAuthorship.Mark(.ai(client: "Claude Code", model: nil),
                                                                     date: Date(timeIntervalSince1970: 0))))
    func session() -> SheetSession {
        var sheet = Sheet(id: 1, name: "R", role: role)
        sheet.cells[CellAddress(a1: "A1")!] = Cell(value: .number(1))
        return SheetSession(workbook: Workbook(sheets: [sheet]))
    }
    func aiWrites(_ value: Int, at a1: String, in session: SheetSession) {
        let ai = AISession.shared
        ai.beginChange(in: session)
        let before = session.revision
        session.apply("AI: Write Cells", author: ai.author) { $0.enter(.number(Decimal(value), format: nil), at: CellAddress(a1: a1)!, sheet: 0) }
        ai.noteChange(in: session, revisionBefore: before)
    }
    func userTypes(_ value: Int, at a1: String, in session: SheetSession) {
        session.apply("Typing") { $0.enter(.number(Decimal(value), format: nil), at: CellAddress(a1: a1)!, sheet: 0) }
    }
    func value(_ a1: String, _ session: SheetSession) -> CellValue? { session.workbook.sheets[0].cells[CellAddress(a1: a1)!]?.value }

    group("ui-ai-1: undoing a round puts back the snapshot when only the AI changed things") {
        let only = session()
        aiWrites(7, at: "B1", in: only)
        aiWrites(8, at: "B2", in: only)
        checkEqual(AISession.shared.undoRound(in: only), .undone, "only the AI changed the workbook")
        checkEqual(value("B1", only), nil, "the round's changes are gone")
    }

    group("ui-ai-2: undoing a round refuses once the user changed the workbook") {
        // 排查第 2 条：AI 改 → 用户改 → AI 再改，AI 的 undo round=true 走到这里。
        let interleaved = session()
        aiWrites(7, at: "B1", in: interleaved)
        userTypes(2, at: "A1", in: interleaved)
        aiWrites(8, at: "B2", in: interleaved)
        check(AISession.shared.lastChangeIsAI(in: interleaved), "the last change is the AI's, as in the report")
        checkEqual(AISession.shared.undoRound(in: interleaved), .userChanged, "AI, then the user, then the AI: refused")
        checkEqual(value("A1", interleaved), .number(2), "the user's 2 is still there")
        checkEqual(value("B2", interleaved), .number(8), "nothing was undone")

        // 横幅上的按钮：AI 改完，用户又改，后面没有 AI 的改动。
        let afterAI = session()
        aiWrites(7, at: "B1", in: afterAI)
        userTypes(2, at: "A1", in: afterAI)
        checkEqual(AISession.shared.undoRound(in: afterAI), .userChanged, "the user changed it after the AI: refused")
        checkEqual(value("A1", afterAI), .number(2), "the user's change stays")
    }

    group("ui-ai-3: a huge number for a string parameter is a parameter error") {
        do {
            _ = try AIToolArguments(["sheet": .number(1e100)]).string("sheet")
            fail("1e100 was accepted as a sheet name")
        } catch let error as AIToolError {
            checkEqual(error.message, "sheet must be a string.", "describe_sheet({\"sheet\": 1e100})")
        }
        checkEqual(try AIToolArguments(["sheet": 2024]).string("sheet"), "2024", "a whole number still reads as digits")
    }
}
