import AppKit
import SkySheetCore
import SkySheetFiles

// MARK: - save_copy（设计 9.2 节）
//
// 默认只写新文件，目标已经有了就拒绝。2026-11-25 加 replace=true（作者报告 FUN-001）：AI 可以直接覆盖已有文件，
// 包括这份工作簿自己的文件，和人打开文件、改完、保存一样；退回靠逐步的版本历史。作者原话：「不要弄太复杂了」。
// 覆盖不另写一套，走自动保存的 WorkbookAutosave：先写临时文件读回核对、第一次覆盖前备份、记进那个文件的历史、
// 在文件协调里比对原字节，别的程序改过就不盖（设计第十节）。
extension AIWorkbookTools {
    /// 覆盖别的文件时用的历史和备份目录。自检换成临时目录，不碰真的。
    static var replaceHistory: (URL) -> WorkbookHistory = { WorkbookHistory(file: $0) }
    static var replaceBackups = BackupStore()

    static func saveCopy(_ arguments: AIToolArguments) throws -> AIToolResult {
        let context = try AIWorkbooks.context(arguments)
        let path = try arguments.requiredString("path")
        let replace = try arguments.bool("replace") ?? false
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        let kind = url.pathExtension.lowercased()
        guard ["xlsx", "csv", "tsv"].contains(kind) else { throw AIToolError("save_copy writes .xlsx, .csv or .tsv files.") }
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) {
            guard !isFolder.boolValue else { throw AIToolError("\(url.path) is a folder, not a file.") }
            guard replace else {
                throw AIToolError("""
                    There is already a file at \(url.path). Choose a new name, or call save_copy again with \
                    replace=true if the user asked to overwrite it.
                    """)
            }
            return try overwrite(url, kind: kind, context: context, arguments: arguments)
        }
        let folder = url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
            throw AIToolError("The folder \(folder.path) does not exist.")
        }
        let workbook = context.workbook
        let temporary = folder.appendingPathComponent(".skysheet-\(UUID().uuidString).\(kind)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        var savedSheets: [String]
        if kind == "xlsx" {
            let result = try XLSXWriter.write(workbook, source: context.document.source, baseline: context.document.baseline)
            try result.data.write(to: temporary)
            _ = try SaveVerifier.verify(try Data(contentsOf: temporary), written: result, workbook: workbook,
                                        source: context.document.source)
            savedSheets = workbook.sheets.map(\.name)
        } else {
            let index = try csvSheet(context, arguments)
            let result = try CSVWriter.write(workbook.sheets[index], styles: workbook.styles,
                                             dateSystem: workbook.dateSystem, format: csvFormat(kind))
            try result.data.write(to: temporary)
            try CSVWriter.verify(try Data(contentsOf: temporary), written: result)
            savedSheets = [workbook.sheets[index].name]
        }
        // moveItem 碰到已经有的文件会失败：写的这一会儿别人放了一个同名文件，也不会被盖掉。
        try FileManager.default.moveItem(at: temporary, to: url)
        return .ok(["saved_to": .string(url.path), "replaced": false, "sheets": .array(savedSheets.map { .string($0) }),
                    "note": "The copy was saved. The open workbook continues using its original location and autosave settings."])
    }

    // MARK: - replace=true

    private static func overwrite(_ url: URL, kind: String, context: AIContext, arguments: AIToolArguments) throws -> AIToolResult {
        let document = context.document
        // 存回这份工作簿自己的文件：等于替用户按 ⌘S，不弹窗。
        if let own = document.fileURL, sameFile(own, url) {
            do { try document.writeBackNow() } catch { throw notReplaced(url, error) }
            let workbook = context.workbook
            let sheets = kind == "xlsx" ? workbook.sheets.map(\.name) : workbook.sheets.prefix(1).map(\.name)
            return .ok(["saved_to": .string(own.path), "replaced": true, "sheets": .array(sheets.map { .string($0) }),
                        "note": "The open workbook's own file now holds all of its changes. Each step is in Version History."])
        }
        // 另一个窗口开着这个文件：先等它写完；还有没进文件的改动就是冲突。盖掉以后让那个窗口重新读。
        let other = AIWorkbooks.open.first { open in
            guard open !== document, let file = open.fileURL else { return false }
            return sameFile(file, url)
        }
        if let other {
            other.finishAutosave()
            if other.isDocumentEdited || other.session?.editing != nil || other.lastSaveIssue != nil
                || other.beforeUnconfirmedAI != nil {
                throw AIToolError("""
                    Conflict: \(url.lastPathComponent) is open in another SkyFolio window with changes that are not in \
                    the file yet. Nothing was overwritten. Ask the user to finish or undo them there first.
                    """)
            }
        }
        var workbook = context.workbook
        var sheets = workbook.sheets.map(\.name)
        var format: CSVFormat?
        if kind != "xlsx" {
            // csv 只放第一张表。要存的表挪到最前面，记进历史的工作簿就和文件对得上：
            // 重开这个 csv 时从历史找回公式和样式（WorkbookHistory.latestWorkbook），找回的第一张就是它。
            workbook.moveSheet(from: try csvSheet(context, arguments), to: 0)
            sheets = [workbook.sheets[0].name]
            format = other?.csvFormat ?? csvFormat(kind)
        }
        // 比对的基准：那个窗口最后读到、写过的内容；没开着就是现在磁盘上的。写的这一会儿文件变了，就不盖。
        let before = try other?.autosaveWriter?.lastFileBytes ?? Data(contentsOf: url)
        let writer = WorkbookAutosave(url: url, bytes: before, format: format,
                                      history: other?.autosaveWriter?.history ?? replaceHistory(url),
                                      backups: replaceBackups, presenter: other)
        let title = String(localized: "AI: Replace with “\(AIWorkbooks.label(document))”")
        writer.submit(WorkbookAutosave.Change(title, workbook: workbook, source: document.source, baseline: document.baseline,
                                              aiRound: AISession.shared.roundID)) { _ in }
        if let error = writer.flush()?.error { throw notReplaced(url, error) }
        var note = "The file was overwritten. Its previous contents stay in Version History and in SkyFolio's backups."
        if let other, let otherURL = other.fileURL, let type = other.fileType {
            do {
                try other.revert(toContentsOf: otherURL, ofType: type)
                note += " The window showing that file was reloaded."
            } catch {
                note += " The window showing that file could not reload (\(error.localizedDescription)); ask the user to reopen it."
            }
        }
        return .ok(["saved_to": .string(url.path), "replaced": true, "sheets": .array(sheets.map { .string($0) }),
                    "note": .string(note)])
    }

    /// 同一个文件：路径一样（解开软链接以后），或者文件系统认的是同一个（大小写不同的写法、硬链接）。
    private static func sameFile(_ a: URL, _ b: URL) -> Bool {
        if a.standardizedFileURL.resolvingSymlinksInPath() == b.standardizedFileURL.resolvingSymlinksInPath() { return true }
        let key = URLResourceKey.fileResourceIdentifierKey
        guard let x = try? a.resourceValues(forKeys: [key]).fileResourceIdentifier,
              let y = try? b.resourceValues(forKeys: [key]).fileResourceIdentifier else { return false }
        return x.isEqual(y)
    }

    private static func notReplaced(_ url: URL, _ error: any Error) -> AIToolError {
        if error is WorkbookAutosave.Issue {
            return AIToolError("""
                Conflict: another app changed \(url.lastPathComponent) after SkyFolio last read it. Nothing was \
                overwritten; this version is kept in Version History. Ask the user how to proceed.
                """)
        }
        let reason = (error as? LocalizedError)?.failureReason.map { " \($0)" } ?? ""
        return AIToolError("\(url.lastPathComponent) was not overwritten: \(error.localizedDescription)\(reason)")
    }

    private static func csvSheet(_ context: AIContext, _ arguments: AIToolArguments) throws -> Int {
        try arguments.string("sheet").map(context.sheetIndex) ?? context.session.sheetIndex
    }

    private static func csvFormat(_ kind: String) -> CSVFormat {
        var format = CSVFormat.standard
        if kind == "tsv" { format.delimiter = "\t" }
        return format
    }
}
