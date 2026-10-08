import AppKit
import SkySheetCore
import SkySheetFiles
import SkySheetMCPKit

// MARK: - 工作簿一级的工具：get_status、open_file、show、save_copy（设计 9.2 节）

@MainActor
enum AIWorkbookTools {
    static func status() -> AIToolResult {
        let documents = AIWorkbooks.open
        guard !documents.isEmpty else {
            return .ok(["workbooks": [],
                        "next_step": "No workbook is open. Ask the user which file to use, then call open_file."])
        }
        let current = try? AIWorkbooks.context(AIToolArguments([:])).document
        return .ok(["workbooks": .array(documents.map { summary($0, current: $0 === current) })])
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
        var selection = session.selection.range.a1
        if session.selection.range.start == session.selection.range.end { selection = session.selection.cursor.a1 }
        return [
            "workbook": .string(AIWorkbooks.label(document)),
            "path": document.fileURL.map { .string($0.path) } ?? .null,
            "kind": DocumentLoader.isDelimitedText(url: document.fileURL, typeName: document.fileType) ? "csv" : "xlsx",
            "unsaved_changes": .bool(document.isDocumentEdited),
            "current": .bool(current),
            "sheets": .array(sheets),
            "user_is_on": .string(session.sheet.name),
            "selection": .string(selection),
        ]
    }

    /// 有内容的格子（有值或公式）围成的范围；只刷了样式的空格子不算。
    static func usedRange(_ sheet: Sheet) -> CellRange? {
        var top = Int.max, left = Int.max, bottom = -1, right = -1
        sheet.cells.forEach { address, cell in
            guard cell.value != .empty || cell.formula != nil else { return }
            top = min(top, address.row)
            bottom = max(bottom, address.row)
            left = min(left, address.column)
            right = max(right, address.column)
        }
        guard bottom >= 0 else { return nil }
        return CellRange(CellAddress(row: top, column: left), CellAddress(row: bottom, column: right))
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
            throw AIToolError("SkySheet opens .xlsx, .csv and .tsv files; \(url.lastPathComponent) is not one of them.")
        }
        let (opened, _) = try await NSDocumentController.shared.openDocument(withContentsOf: url, display: true)
        guard let document = opened as? WorkbookDocument else { throw AIToolError("SkySheet could not open that file.") }
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
            let range = try AIFormat.range(text).range
            context.session.select(range.start)
            context.session.select(range.end, extend: true)
        }
        context.document.windowControllers.first?.window?.orderFrontRegardless()
        return .ok(["shown": .string("\(context.workbook.sheets[index].name)!\(context.session.selection.range.a1)")])
    }

    // MARK: - save_copy

    /// 存一份新文件。目标已经有了就拒绝（AI 从不覆盖文件，设计 9.2 节）；和用户存一样，先写临时文件、读回来核对，
    /// 全对才挪到目标位置。打开着的文档还是对着用户自己的文件。
    static func saveCopy(_ arguments: AIToolArguments) throws -> AIToolResult {
        let context = try AIWorkbooks.context(arguments)
        let path = try arguments.requiredString("path")
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw AIToolError("There is already a file at \(url.path). SkySheet never overwrites files for AI; pick a new name.")
        }
        let folder = url.deletingLastPathComponent()
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
            throw AIToolError("The folder \(folder.path) does not exist.")
        }
        let workbook = context.workbook
        let kind = url.pathExtension.lowercased()
        let temporary = folder.appendingPathComponent(".skysheet-\(UUID().uuidString).\(kind)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        var savedSheets: [String]
        switch kind {
        case "xlsx":
            let result = try XLSXWriter.write(workbook, source: context.document.source, baseline: context.document.baseline)
            try result.data.write(to: temporary)
            _ = try SaveVerifier.verify(try Data(contentsOf: temporary), written: result, workbook: workbook,
                                        source: context.document.source)
            savedSheets = workbook.sheets.map(\.name)
        case "csv", "tsv":
            let index = try arguments.string("sheet").map(context.sheetIndex) ?? context.session.sheetIndex
            var format = CSVFormat.standard
            if kind == "tsv" { format.delimiter = "\t" }
            let result = try CSVWriter.write(workbook.sheets[index], styles: workbook.styles,
                                             dateSystem: workbook.dateSystem, format: format)
            try result.data.write(to: temporary)
            try CSVWriter.verify(try Data(contentsOf: temporary), written: result)
            savedSheets = [workbook.sheets[index].name]
        default:
            throw AIToolError("save_copy writes .xlsx, .csv or .tsv files.")
        }
        // moveItem 碰到已经有的文件会失败：写的这一会儿别人放了一个同名文件，也不会被盖掉。
        try FileManager.default.moveItem(at: temporary, to: url)
        return .ok(["saved_to": .string(url.path), "sheets": .array(savedSheets.map { .string($0) }),
                    "note": "The user's own file is unchanged; only Cmd+S in SkySheet writes to it."])
    }
}
