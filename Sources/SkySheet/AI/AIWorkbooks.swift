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

    /// 改工作簿：开这一轮、一步撤销、记下改到的格子（高亮）。`cells` 在改完以后算（新建的 sheet 才有编号）。
    func change(_ actionName: String, _ edit: (inout Workbook) throws -> Void,
                cells: (Workbook) -> [Int: Set<CellAddress>] = { _ in [:] }) throws {
        let ai = AISession.shared
        ai.beginChange(in: session)
        let before = session.revision
        try AIUndoGrouping.step(session.undoManager) {
            try session.apply(actionName, author: ai.author, edit)
        }
        guard session.revision != before else { return }
        ai.noteChange(in: session, revisionBefore: before, cells: cells(session.workbook))
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
            throw AIToolError("No workbook is open in SkySheet. Ask the user which file to use, then call open_file.")
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
