import AppKit
import SkySheetCore
import SkySheetFiles
import SkySheetMCPKit

/// save_copy replace=true（作者报告 FUN-001，2026-11-25）：AI 可以覆盖已有文件，包括工作簿自己的文件。
/// 每次覆盖先备份、记进那个文件的历史；别的程序改过、别的窗口有没进文件的改动时返回冲突，什么都不盖。
/// 照 closeDecisionChecks 的样子开真的文档，历史和备份都放临时目录。
@MainActor
func saveCopyReplaceChecks() {
    group("ui-ai-6: save_copy overwrites an existing file only with replace=true") {
        let folder = try makeTemporaryDirectory()
        let historyRoot = folder.appendingPathComponent("History")
        let documentBackups = BackupStore(root: folder.appendingPathComponent("Backups"))
        let replaceBackups = BackupStore(root: folder.appendingPathComponent("ReplaceBackups"))
        let (savedHistory, savedBackups) = (AIWorkbookTools.replaceHistory, AIWorkbookTools.replaceBackups)
        AIWorkbookTools.replaceHistory = { WorkbookHistory(file: $0, root: historyRoot) }
        AIWorkbookTools.replaceBackups = replaceBackups
        defer { AIWorkbookTools.replaceHistory = savedHistory; AIWorkbookTools.replaceBackups = savedBackups }

        let a1 = CellAddress(row: 0, column: 0)
        func value(_ url: URL) throws -> CellValue? { try LoadedWorkbook(contentsOf: url).workbook.sheets[0].cells[a1]?.value }
        func copyFixture(_ name: String) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try FileManager.default.copyItem(at: fixtureURL("IronCalc/arithmetic.xlsx"), to: url)
            return url
        }
        func attach(_ doc: WorkbookDocument, _ url: URL) {
            guard let loaded = doc.loaded else { return fail("no loaded workbook for \(url.lastPathComponent)") }
            doc.attachAutosave(url: url, loaded: loaded, history: WorkbookHistory(file: url, root: historyRoot),
                               backups: documentBackups)
        }
        func open(_ url: URL) throws -> WorkbookDocument {
            let doc = WorkbookDocument()
            doc.savePreferences = UserDefaults(suiteName: "SkyFolioChecks.\(UUID().uuidString)")!
            doc.fileURL = url
            doc.fileType = WorkbookDocument.xlsxType
            try doc.read(from: url, ofType: WorkbookDocument.xlsxType)
            doc.makeWindowControllers()
            attach(doc, url)
            NSDocumentController.shared.addDocument(doc)
            return doc
        }
        func type(_ text: String, in doc: WorkbookDocument) {
            guard let session = doc.session else { return fail("no session") }
            session.select(a1)
            session.beginEditing(.typing, text: text)
            session.commitEditing(groupUndo: true)
            doc.finishAutosave()
        }
        func call(_ arguments: JSONValue) throws -> AIToolResult { try AIWorkbookTools.saveCopy(AIToolArguments(arguments)) }
        /// 工具必须拒绝；回拒绝的话。
        func refused(_ what: String, _ arguments: JSONValue) -> String {
            do {
                _ = try call(arguments)
                fail("\(what): went through")
            } catch let error as AIToolError {
                return error.message
            } catch {
                fail("\(what): unexpected \(error)")
            }
            return ""
        }

        let mine = try copyFixture("Mine.xlsx")
        let theirs = try copyFixture("Theirs.xlsx")
        let original = try value(theirs)
        check(original != .number(77) && original != .number(88), "the fixture's A1 differs from what the checks type")
        let docA = try open(mine)
        defer { docA.close() }
        let workbook: JSONValue = .string(mine.path)
        type("77", in: docA)
        checkEqual(try value(mine), .number(77), "typing autosaves the open workbook")

        // 不传 replace、传 false：已有的文件一个字节不动，拒绝里说清楚怎么覆盖。
        let untouched = try Data(contentsOf: theirs)
        let refusal = refused("existing file, no replace", ["path": .string(theirs.path), "workbook": workbook])
        check(refusal.contains("replace=true"), "the refusal says how to overwrite: \(refusal)")
        _ = refused("existing file, replace=false", ["path": .string(theirs.path), "replace": false, "workbook": workbook])
        checkEqual(try Data(contentsOf: theirs), untouched, "without replace=true the existing file is untouched")

        // 新文件照旧，回 replaced=false。
        let fresh = folder.appendingPathComponent("Fresh.xlsx")
        let created = try call(["path": .string(fresh.path), "workbook": workbook])
        checkEqual(created.payload["replaced"]?.boolValue, false, "a new file is not a replacement")
        checkEqual(try value(fresh), .number(77), "the new copy holds the workbook")

        // 覆盖一个没开着的文件：先备份，记进那个文件的历史，原来的内容能找回。
        let replaced = try call(["path": .string(theirs.path), "replace": true, "workbook": workbook])
        checkEqual(replaced.payload["replaced"]?.boolValue, true, "the result says the file was replaced")
        checkEqual(replaced.payload["saved_to"]?.stringValue, theirs.path, "the result gives the saved path")
        checkEqual(try value(theirs), .number(77), "the existing file now holds the workbook")
        check(!replaceBackups.backups(of: theirs).isEmpty, "the overwritten file was backed up first")
        let theirHistory = WorkbookHistory(file: theirs, root: historyRoot)
        let versions = try theirHistory.versions()
        checkEqual(versions.map(\.title), ["AI: Replace with “Mine.xlsx”", "Opened Version"],
                   "the overwrite is a step in that file's history")
        if versions.count == 2 {
            checkEqual(try theirHistory.load(versions[1]).workbook.sheets[0].cells[a1]?.value, original,
                       "the previous contents can be restored from history")
        }
        checkEqual(docA.fileURL, mine, "the open workbook keeps its own file")

        // 另一个窗口开着它、编辑框里还有字：冲突，不盖。
        let docB = try open(theirs)
        defer { docB.close() }
        docB.session?.select(a1)
        docB.session?.beginEditing(.typing, text: "5")
        let beforePending = try Data(contentsOf: theirs)
        let pending = refused("another window is mid-edit", ["path": .string(theirs.path), "replace": true, "workbook": workbook])
        check(pending.hasPrefix("Conflict"), "unsaved edits in another window are a conflict: \(pending)")
        checkEqual(try Data(contentsOf: theirs), beforePending, "the conflict leaves the file alone")
        docB.session?.cancelEditing()

        // 那个窗口没有没进文件的改动：盖掉，窗口重新读。
        type("88", in: docA)
        let reloaded = try call(["path": .string(theirs.path), "replace": true, "workbook": workbook])
        checkEqual(reloaded.payload["replaced"]?.boolValue, true, "replaced while another window shows it")
        checkEqual(try value(theirs), .number(88), "the file holds the new contents")
        checkEqual(docB.session?.workbook.sheets[0].cells[a1]?.value, .number(88), "the window showing that file was reloaded")
        check(!docB.isDocumentEdited, "the reloaded window has nothing unsaved")
        attach(docB, theirs)

        // 别的程序在那个窗口读过以后改了文件：冲突，别人的版本留着。
        let external = Data("Changed by another app".utf8)
        try external.write(to: theirs, options: .atomic)
        let changed = refused("another app changed the file", ["path": .string(theirs.path), "replace": true, "workbook": workbook])
        check(changed.hasPrefix("Conflict"), "an external change is a conflict: \(changed)")
        checkEqual(try Data(contentsOf: theirs), external, "the other app's version is kept")

        // 存回自己的文件：打开了「AI 改动按 ⌘S 才写回」时，等着的 AI 改动这时写回。
        docA.savePreferences.set(true, forKey: WorkbookDocument.aiConfirmationKey)
        let author = AIAuthorship.Mark.Author.ai(client: "Test", model: nil)
        let role = SheetRole.ai(AIAuthorship(created: .init(author, date: Date(timeIntervalSince1970: 1))))
        guard let session = docA.session else { return fail("no session") }
        let held = try Data(contentsOf: mine)
        try session.apply("AI: Add Sheet", author: author, groupUndo: true) { _ = try $0.addSheet(named: "Review", role: role) }
        docA.finishAutosave()
        checkEqual(try Data(contentsOf: mine), held, "with confirmation on, the AI edit waits")
        let own = try call(["path": .string(mine.path), "replace": true, "workbook": workbook])
        checkEqual(own.payload["replaced"]?.boolValue, true, "saving over the workbook's own file is a replacement")
        check(try LoadedWorkbook(contentsOf: mine).workbook.sheetIndex(named: "Review") != nil,
              "replace=true on the workbook's own file writes the waiting AI edit")
        check(!docA.isDocumentEdited, "nothing is left unsaved")
        docA.savePreferences.removeObject(forKey: WorkbookDocument.aiConfirmationKey)

        // 自己的文件被别的程序改过：冲突，别人的版本留着，改动在历史里。
        try external.write(to: mine, options: .atomic)
        type("99", in: docA)
        let ownConflict = refused("own file changed by another app", ["path": .string(mine.path), "replace": true, "workbook": workbook])
        check(ownConflict.hasPrefix("Conflict"), "an external change to the own file is a conflict: \(ownConflict)")
        checkEqual(try Data(contentsOf: mine), external, "the other app's version of the own file is kept")
    }
}
