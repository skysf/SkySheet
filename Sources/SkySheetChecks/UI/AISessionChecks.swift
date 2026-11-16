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

    refusedEditsKeepUndoHistory(role: role)

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

/// 这个 PR 加的拒绝（会改原始 sheet 的公式、合并超过上限、整轮撤销）不许动撤销和重做栈（PR #15 审查）。以前拒绝在
/// AIContext.change 开了撤销组以后才抛：关上的空组把用户刚 ⌘Z 撤掉的那一步从重做栈里挤掉了，撤销栈顶也换成了一个没名字的空组。
/// 照 App 的样子搭：一个文档、真的撤销管理器（按事件分组，和窗口里一样），工具按 MCP 的参数直接调。
@MainActor
private func refusedEditsKeepUndoHistory(role: SheetRole) {
    func open() -> (WorkbookDocument, SheetSession, UndoManager) {
        var original = Sheet(id: 1, name: "Orig")
        original.cells[CellAddress(a1: "A1")!] = Cell(formula: CellFormula(source: "R!A1"))
        var result = Sheet(id: 2, name: "R", role: role)
        result.cells[CellAddress(a1: "A1")!] = Cell(value: .number(1))
        let session = SheetSession(workbook: Workbook(sheets: [original, result]))
        let manager = UndoManager()
        session.undoManager = manager
        let document = WorkbookDocument()
        document.session = session
        NSDocumentController.shared.addDocument(document)
        AIWorkbooks.makeCurrent(document)
        return (document, session, manager)
    }
    func stacks(_ manager: UndoManager) -> String {
        "undo \(manager.canUndo) \"\(manager.undoActionName)\", redo \(manager.canRedo) \"\(manager.redoActionName)\""
    }
    func userTypes(_ value: Int, at a1: String, _ session: SheetSession, _ manager: UndoManager) {
        AIUndoGrouping.step(manager) {
            session.apply("User step") { $0.enter(.number(Decimal(value), format: nil), at: CellAddress(a1: a1)!, sheet: 1) }
        }
    }
    /// 工具必须拒绝，而且工作簿、改动次数、撤销和重做栈都和之前一样。
    func refused(_ what: String, _ session: SheetSession, _ manager: UndoManager, _ call: () throws -> Void) {
        let workbook = session.workbook, revision = session.revision, before = stacks(manager)
        do {
            try call()
            fail("\(what): went through")
        } catch is AIToolError {
        } catch {
            fail("\(what): unexpected \(error)")
        }
        check(session.workbook == workbook && session.revision == revision, "\(what): nothing changed")
        checkEqual(stacks(manager), before, "\(what): undo and redo are as the user left them")
    }

    group("ui-ai-4: refused AI edits leave the user's undo and redo alone") {
        let edits: [(String, () throws -> Void)] = [
            ("rename R", { _ = try AIWriteTools.editSheet(AIToolArguments(["sheet": "R", "rename": "NewR"])) }),
            ("delete R", { _ = try AIWriteTools.editSheet(AIToolArguments(["sheet": "R", "delete": true])) }),
            ("insert row 1", { _ = try AIRowColumnTools.edit(AIToolArguments(["sheet": "R", "rows": "1", "insert": true])) }),
            ("delete row 1", { _ = try AIRowColumnTools.edit(AIToolArguments(["sheet": "R", "rows": "1", "delete": true])) }),
            ("merge 52,000 cells", { _ = try AIWriteTools.formatCells(AIToolArguments(["sheet": "R", "range": "A1:Z2000", "merge": true])) }),
        ]
        for (what, call) in edits {
            let (document, session, manager) = open()
            // 审查的复现：用户写一格、再 ⌘Z，重做栈上有这一步。
            userTypes(3, at: "B1", session, manager)
            userTypes(4, at: "C1", session, manager)
            manager.undo()
            refused(what, session, manager, call)
            NSDocumentController.shared.removeDocument(document)
        }

        // 整轮撤销被拒：AI 改 → 用户改 → AI 改两步 → AI 撤一步（重做栈上有 AI 那一步），再要整轮撤销。
        let (document, session, manager) = open()
        let context = AIContext(document: document, session: session)
        @MainActor func aiWrites(_ value: Int, at a1: String) throws {
            try context.change("AI step") { $0.enter(.number(Decimal(value), format: nil), at: CellAddress(a1: a1)!, sheet: 1) }
        }
        try aiWrites(7, at: "B1")
        userTypes(2, at: "A2", session, manager)
        try aiWrites(8, at: "B2")
        try aiWrites(9, at: "B3")
        _ = try AIWriteTools.undo(AIToolArguments([:]))
        refused("undo round=true after the user changed it", session, manager) {
            _ = try AIWriteTools.undo(AIToolArguments(["round": true]))
        }
        let before = stacks(manager)
        checkEqual(AISession.shared.undoRound(in: session), .userChanged, "the banner's button is refused too")
        checkEqual(stacks(manager), before, "the banner's refusal leaves undo and redo alone")
        NSDocumentController.shared.removeDocument(document)
    }
}
