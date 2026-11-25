import AppKit
import SkySheetCore
import SkySheetFiles
import SkySheetMCPKit

// MARK: - 工作簿一级的工具：get_status、open_file、show（设计 9.2 节）；save_copy 在 AIWorkbookTools+SaveCopy

@MainActor
enum AIWorkbookTools {
    static func status() -> AIToolResult {
        let documents = AIWorkbooks.open
        let info = app
        // 旧客户端按 skysheet 取版本，新客户端使用与文稿类型无关的 app 键。
        var result: [String: JSONValue] = ["app": info, "skysheet": info, "workbooks": []]
        if documents.isEmpty {
            result["next_step"] = "No workbook is open. Ask the user which file to use, then call open_file."
        } else {
            let current = try? AIWorkbooks.context(AIToolArguments([:])).document
            result["workbooks"] = .array(documents.map { summary($0, current: $0 === current) })
        }
        return .ok(.object(result))
    }

    /// 这个 SkySheet 是哪一版、什么时候打的包。模型看不到握手里 serverInfo 的版本：用户问「SkySheet 是什么版本、
    /// 什么时候的」，只能从这里答（2026-10-14 桌面版的聊天答不上来，跑去网上搜）。
    private static var app: JSONValue {
        var info: [String: JSONValue] = ["version": .string(MCPBridge.appVersion(of: .main))]
        if let built = MCPBridge.appBuildDate(of: .main) { info["built"] = .string(built) }
        return .object(info)
    }

    /// 一个工作簿的概况（get_status、open_file 都回它）。
    static func summary(_ document: WorkbookDocument, current: Bool) -> JSONValue {
        guard let session = document.session else { return [:] }
        let workbook = session.workbook
        let sheets: [JSONValue] = workbook.sheets.map { sheet in
            var item: [String: JSONValue] = [
                "name": .string(sheet.name),
                "role": sheet.role.isAI ? "ai" : "original",
                "used_range": usedRange(sheet).map { .string($0.a1) } ?? .null,
            ]
            if let authorship = sheet.role.authorship { item["by"] = .string(byline(authorship.created)) }
            if sheet.visibility != .visible { item["hidden"] = true }
            return .object(item)
        }
        // 整列整行写成 C:E、3:5。
        var selection = session.selection.range.label
        if session.selection.range.start == session.selection.range.end { selection = session.selection.cursor.a1 }
        return [
            "workbook": .string(AIWorkbooks.label(document)),
            "path": document.fileURL.map { .string($0.path) } ?? .null,
            "kind": LoadedWorkbook.isDelimitedText(url: document.fileURL, typeName: document.fileType) ? "csv" : "xlsx",
            "unsaved_changes": .bool(document.isDocumentEdited),
            "current": .bool(current),
            "sheets": .array(sheets),
            "user_is_on": .string(session.sheet.name),
            "selection": .string(selection),
        ]
    }

    /// 有内容的格子（有值或公式）围成的范围；只刷了样式的空格子不算（Sheet.contentRange）。
    static func usedRange(_ sheet: Sheet) -> CellRange? {
        sheet.contentRange
    }

    static func byline(_ mark: AIAuthorship.Mark) -> String {
        switch mark.author {
        case .user: return "the user"
        case .ai(let client, let model): return model.map { "\(client) (\($0))" } ?? client
        }
    }

    // MARK: - open_file

    static func openFile(_ arguments: AIToolArguments) async throws -> AIToolResult {
        let path = try arguments.requiredString("path")
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { throw AIToolError("There is no file at \(url.path).") }
        guard ["xlsx", "csv", "tsv", "txt"].contains(url.pathExtension.lowercased()) else {
            throw AIToolError("SkyFolio opens .xlsx, .csv and .tsv files; \(url.lastPathComponent) is not one of them.")
        }
        let (opened, _) = try await NSDocumentController.shared.openDocument(withContentsOf: url, display: true)
        guard let document = opened as? WorkbookDocument else { throw AIToolError("SkyFolio could not open that file.") }
        AIWorkbooks.makeCurrent(document)
        return .ok(summary(document, current: true))
    }

    // MARK: - show

    /// 切到那张 sheet、选中那块，把窗口摆到最前面但不抢键盘（orderFrontRegardless 不激活 App）。
    static func show(_ arguments: AIToolArguments) throws -> AIToolResult {
        let context = try AIWorkbooks.context(arguments)
        let index = try context.sheetIndex(try arguments.requiredString("sheet"))
        context.session.showSheet(index)
        if let text = try arguments.string("range") {
            context.session.select(try AIFormat.range(text).range)
        }
        context.document.windowControllers.first?.window?.orderFrontRegardless()
        return .ok(["shown": .string("\(context.workbook.sheets[index].name)!\(context.session.selection.range.label)")])
    }
}
