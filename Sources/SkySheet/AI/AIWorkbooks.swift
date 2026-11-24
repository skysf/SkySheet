import AppKit
import SkySheetCore

// MARK: - AI 的这次调用对的是哪个工作簿、哪张 sheet（设计 9.2 节）
//
// 工具都收一个可选的 `workbook`（文件名或路径，get_status 里列着）。不给就用「当前的」：AI 上次打开或用过的那个，
// 其次是最前面的窗口，只开着一个就是它。

/// 一次调用用到的工作簿。
@MainActor
struct AIContext {
    let document: WorkbookDocument
    let session: SheetSession

    var workbook: Workbook { session.workbook }

    /// 给 AI 看的名字：文件名；没存过的用窗口标题。
    var label: String { AIWorkbooks.label(document) }

    func sheetIndex(_ name: String) throws -> Int {
        if let index = workbook.sheetIndex(named: name.trimmingCharacters(in: .whitespaces)) { return index }
        let names = workbook.sheets.map(\.name).joined(separator: ", ")
        throw AIToolError("\(label) has no sheet named \(name). Its sheets: \(names).")
    }

    /// 写入类工具只认 AI 的 sheet（设计 9.3 节第 1 条）。
    func requireAISheet(_ index: Int) throws {
        let sheet = workbook.sheets[index]
        guard sheet.role.isAI else {
            throw AIToolError("""
                \(sheet.name) is original data, which is read-only for you. Use add_sheet with \
                copy_from="\(sheet.name)" and change the copy instead.
                """)
        }
    }

    /// 改名、删表、插删行列会连带改原始 sheet 的公式时的拒绝（设计 9.3 节第 7 条）：哪几格、会怎样、可以怎么办。
    static func refusal(_ conflict: OriginalFormulasWouldChange, sheet: String, effect: String, instead: String) -> AIToolError {
        let shown = conflict.cells.prefix(10).joined(separator: ", ")
        let cells = conflict.cells.count > 10 ? "\(shown) and \(conflict.cells.count - 10) more" : shown
        return AIToolError("""
            Formulas in original sheets refer to \(sheet): \(cells). \(effect), and original sheets are read-only for \
            you, so nothing changed. \(instead)
            """)
    }

    /// 改名、删表、插删行列：先在副本上做、比原始 sheet 的公式原文（设计 9.3 节第 7 条），会变就在开这一轮、开撤销组**之前**
    /// 拒绝（`refusal` 给拒绝的话）。组开了再抛错，关上的空组会把用户刚 ⌘Z 撤掉的那一步挤出重做栈（PR #15 审查实测）。
    /// 通过了才走 `change`，把副本上做好的结果换上去：都在主线程上、中间没人动过工作簿，和在组里现做一遍一样。
    /// `edit` 自己的错误（名字不合规矩、最后一张表……）照旧在 `change` 里抛，和以前一模一样。
    func changeSparingOriginals(_ actionName: String, refusal: (OriginalFormulasWouldChange) -> AIToolError,
                                _ edit: (inout Workbook) throws -> Void) throws {
        var trial = workbook
        var failure: Error?
        do {
            try trial.editSparingOriginalFormulas(edit)
        } catch let conflict as OriginalFormulasWouldChange {
            throw refusal(conflict)
        } catch {
            failure = error
        }
        try change(actionName) { workbook in
            if let failure { throw failure }
            workbook = trial
        }
    }

    /// 改工作簿：开这一轮、一步撤销、记下改到的格子（高亮）。`cells` 在改完以后算（新建的 sheet 才有编号）。
    /// 要拒绝的先在调它之前拒绝：在 `edit` 里抛错会留下一个空的撤销组、清掉重做栈。
    ///
    /// 先在副本上改一遍：碰到 SkySheet 写不回去的公式占着的格子（算不出来的共享公式组、模拟运算表），就在开这一轮、
    /// 开撤销组之前拒绝（PR #17 第一轮审查第 3–5 条）。通过了把副本上的结果换上去，和在组里现做一遍一样；
    /// `edit` 自己的错误照旧在组里抛，和以前一模一样。
    func change(_ actionName: String, _ edit: (inout Workbook) throws -> Void,
                cells: (Workbook) -> [Int: Set<CellAddress>] = { _ in [:] }) throws {
        var trial = session.workbook
        var failure: Error?
        do {
            try edit(&trial)
        } catch {
            failure = error
        }
        if failure == nil, let locked = trial.lockedFormulaChange(since: session.workbook) {
            throw AIToolError(Self.message(locked))
        }
        let ai = AISession.shared
        ai.beginChange(in: session)
        let before = session.revision
        try AIUndoGrouping.step(session.undoManager) {
            try session.apply(actionName, author: ai.author) { workbook in
                if let failure { throw failure }
                workbook = trial
            }
        }
        guard session.revision != before else { return }
        ai.noteChange(in: session, revisionBefore: before, cells: cells(session.workbook))
    }

    /// 给 AI 的话：哪一格、为什么不能改。
    static func message(_ locked: LockedFormulaChange) -> String {
        let cell = "\(FormulaRewriter.quotedSheetName(locked.sheet))!\(locked.cell.a1)"
        switch locked.reason {
        case .sharedFormula(let range):
            return """
                \(cell) is part of an Excel shared formula in \(range.a1) whose formulas SkyFolio can't work out, so none \
                of its cells can be changed and nothing changed. Leave \(range.a1) as it is.
                """
        case .dataTable(let range):
            return """
                \(cell) is part of the Excel data table in \(range.a1), and a data table can't be changed in part, \
                so nothing changed.
                """
        }
    }
}

@MainActor
enum AIWorkbooks {
    /// AI 上次打开或用过的那个。
    private static weak var current: WorkbookDocument?

    static var open: [WorkbookDocument] {
        NSDocumentController.shared.documents.compactMap { $0 as? WorkbookDocument }.filter { $0.session != nil }
    }

    static func label(_ document: WorkbookDocument) -> String {
        document.fileURL?.lastPathComponent ?? document.displayName ?? "Untitled"
    }

    static func makeCurrent(_ document: WorkbookDocument) {
        current = document
    }

    static func context(_ arguments: AIToolArguments) throws -> AIContext {
        let document = try resolve(try arguments.string("workbook"))
        guard let session = document.session else { throw AIToolError("That workbook has no window yet. Try again.") }
        current = document
        return AIContext(document: document, session: session)
    }

    private static func resolve(_ name: String?) throws -> WorkbookDocument {
        let documents = open
        guard !documents.isEmpty else {
            throw AIToolError("No workbook is open in SkyFolio. Ask the user which file to use, then call open_file.")
        }
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            let wanted = name.trimmingCharacters(in: .whitespaces)
            let path = (wanted as NSString).expandingTildeInPath
            let matches = documents.filter { document in
                if let url = document.fileURL, url.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path {
                    return true
                }
                return label(document).caseInsensitiveCompare(wanted) == .orderedSame
                    || (document.displayName ?? "").caseInsensitiveCompare(wanted) == .orderedSame
            }
            guard matches.count == 1, let match = matches.first else {
                let names = documents.map { label($0) }.joined(separator: ", ")
                throw AIToolError(matches.isEmpty
                    ? "No open workbook is called \(wanted). Open workbooks: \(names). Use open_file to open another."
                    : "Several open workbooks are called \(wanted); pass the full path instead.")
            }
            return match
        }
        if let current, documents.contains(where: { $0 === current }) { return current }
        if let front = NSDocumentController.shared.currentDocument as? WorkbookDocument, front.session != nil { return front }
        if documents.count == 1 { return documents[0] }
        let names = documents.map { label($0) }.joined(separator: ", ")
        throw AIToolError("Several workbooks are open (\(names)); pass workbook to say which one.")
    }
}
