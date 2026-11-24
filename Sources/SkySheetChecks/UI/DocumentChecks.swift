import AppKit
import ObjectiveC.runtime
import SkySheetCore
import SkySheetFiles

@MainActor
func closeDecisionChecks() {
    group("mac: commit, undo and reopen an autosaved workbook with its intermediate steps") {
        let folder = try makeTemporaryDirectory()
        let url = folder.appendingPathComponent("Autosave.xlsx")
        try FileManager.default.copyItem(at: fixtureURL("IronCalc/arithmetic.xlsx"), to: url)
        let history = WorkbookHistory(file: url, root: folder.appendingPathComponent("History"))
        let backups = BackupStore(root: folder.appendingPathComponent("Backup"))
        func open() throws -> WorkbookDocument {
            let doc = WorkbookDocument()
            doc.fileURL = url
            doc.fileType = WorkbookDocument.xlsxType
            try doc.read(from: url, ofType: WorkbookDocument.xlsxType)
            doc.makeWindowControllers()
            if let loaded = doc.loaded { doc.attachAutosave(url: url, loaded: loaded, history: history, backups: backups) }
            return doc
        }
        let doc = try open()
        guard let session = doc.session else { return fail("no document session") }
        let a1 = CellAddress(row: 0, column: 0)
        session.select(a1)
        for text in ["7", "9"] {
            session.beginEditing(.typing, text: text)
            session.commitEditing(groupUndo: true)
        }
        doc.finishAutosave()
        checkEqual(try LoadedWorkbook(contentsOf: url).workbook.sheets[0].cells[a1]?.value, .number(9), "real document autosaved")
        doc.undoManager?.undo()
        doc.finishAutosave()
        checkEqual(try LoadedWorkbook(contentsOf: url).workbook.sheets[0].cells[a1]?.value, .number(7), "undo also saved")
        doc.close()
        let reopened = try open()
        defer { reopened.close() }
        let versions = try history.versions()
        checkEqual(versions.count, 4, "initial version, both edits and undo")
        guard versions.count == 4 else { return }
        try reopened.restoreVersion(versions[1])
        reopened.finishAutosave()
        checkEqual(try LoadedWorkbook(contentsOf: url).workbook.sheets[0].cells[a1]?.value, .number(9), "restored after document was closed and reopened")
        checkEqual(try history.versions().count, 5, "restore has its own step")
        guard let editing = reopened.session else { return fail("no reopened session") }
        let beforeAI = try Data(contentsOf: url)
        try editing.apply("AI: Add Sheet", author: .ai(client: "Test", model: nil), groupUndo: true) {
            _ = try $0.addSheet(named: "Analysis")
        }
        reopened.finishAutosave()
        checkEqual(try Data(contentsOf: url), beforeAI, "unconfirmed AI edits only enter local history")
        checkEqual(try history.versions().first?.title, "AI: Add Sheet", "AI edit is recorded")
        reopened.save(withDelegate: nil, didSave: nil, contextInfo: nil)
        check(try LoadedWorkbook(contentsOf: url).workbook.sheetIndex(named: "Analysis") != nil, "explicit approval writes AI results")
    }
    group("ui-22: close decision sees the real document undo manager's dirty state") {
        let session = SheetSession(workbook: Workbook(sheets: [Sheet(id: 1, name: "Main")]))
        let document = WorkbookDocument()
        document.session = session
        session.undoManager = document.undoManager
        check(!document.isDocumentEdited, "document starts clean")
        session.beginEditing(.typing, text: "before close decision")
        let delegate = CloseDecisionProbe()
        let queried = observeCloseDirty(document) {
            document.canClose(withDelegate: delegate, shouldClose: #selector(CloseDecisionProbe.document(_:shouldClose:contextInfo:)), contextInfo: nil)
        }
        check(queried.contains(true), "NSDocument sees dirty=true before deciding whether to ask for a save")
        checkEqual(document.undoManager?.groupingLevel, 0, "pending undo group is closed synchronously")
        check(document.isDocumentEdited, "real document knows about its only change")
        checkEqual(delegate.valueAtDecision, .text("before close decision"), "close delegate sees committed input")
        check(delegate.editingEnded, "editing ends before close decision")
        // 主断言已能判红；旧实现遗留自动组时不继续登记，以免系统吞掉异常让整个自检挂住。
        guard document.undoManager?.groupingLevel == 0 else { return }
        let revision = session.revision
        session.commitEditing()
        checkEqual(session.revision, revision, "repeat commit does not duplicate the edit")
        document.undoManager?.undo()
        check(!document.isDocumentEdited, "undo returns the document to clean without double counting")
        checkEqual(session.sheet.cells[CellAddress(a1: "A1")!]?.value, nil, "undo removes only pending input")
        document.undoManager?.redo()
        check(document.isDocumentEdited, "redo restores dirty state")
        // 保存确认可以取消；继续输入和再次关窗必须仍能登记撤销，不能留下已手动结束的事件组。
        session.beginEditing(.typing, text: "continued input")
        session.commitEditing()
        let retried = observeCloseDirty(document) {
            document.canClose(withDelegate: delegate, shouldClose: #selector(CloseDecisionProbe.document(_:shouldClose:contextInfo:)), contextInfo: nil)
        }
        check(retried.contains(true), "repeated close still observes the continued edit")
        document.undoManager?.undo()
        checkEqual(session.sheet.cells[CellAddress(a1: "A1")!]?.value, .text("before close decision"), "continued typing remains a separate undo step")
        document.undoManager?.undo()
        check(!document.isDocumentEdited, "undoing both edits returns to clean")
    }
    group("ui-22: unchanged pending input leaves a clean document clean") {
        let document = WorkbookDocument()
        let session = SheetSession(workbook: Workbook(sheets: [Sheet(id: 1, name: "Main")]))
        document.session = session
        session.undoManager = document.undoManager
        session.beginEditing(.editing)
        let delegate = CloseDecisionProbe()
        let queried = observeCloseDirty(document) {
            document.canClose(withDelegate: delegate, shouldClose: #selector(CloseDecisionProbe.document(_:shouldClose:contextInfo:)), contextInfo: nil)
        }
        check(!queried.isEmpty && queried.allSatisfy { !$0 }, "no-op input never asks for a save")
        check(!document.isDocumentEdited, "no-op commit stays clean")
    }
    group("ui-22: alternate spelling of the same number does not create a dirty empty group") {
        let document = WorkbookDocument()
        let address = CellAddress(a1: "A1")!
        var sheet = Sheet(id: 1, name: "Main")
        sheet.cells[address] = Cell(value: .number(1))
        let session = SheetSession(workbook: Workbook(sheets: [sheet]))
        document.session = session
        session.undoManager = document.undoManager
        session.beginEditing(.typing, text: "1.0")
        let delegate = CloseDecisionProbe()
        let queried = observeCloseDirty(document) {
            document.canClose(withDelegate: delegate, shouldClose: #selector(CloseDecisionProbe.document(_:shouldClose:contextInfo:)), contextInfo: nil)
        }
        check(!queried.isEmpty && queried.allSatisfy { !$0 }, "equivalent parsed value never asks for a save")
        check(!document.isDocumentEdited, "equivalent parsed value stays clean")
        checkEqual(session.revision, 0, "equivalent parsed value makes no revision")
    }
    group("ui-29: quitting commits pending editor text before documents are filtered") {
        // 退出时系统先问 hasEditedDocuments，只对标脏的文档调 canClose；只有编辑框里有字的文档必须在这一问之前提交。
        // 走 Objective-C 派发（静态类型是 NSDocumentController），和 AppKit 调它的方式一样。
        let controller: NSDocumentController = NSDocumentController.shared
        check(controller is WorkbookDocumentController, "shared document controller is the subclass (created before any document)")
        let address = CellAddress(a1: "A1")!
        for text in ["", "typed before quit"] {
            let document = WorkbookDocument()
            let session = SheetSession(workbook: Workbook(sheets: [Sheet(id: 1, name: "Main")]))
            document.session = session
            session.undoManager = document.undoManager
            controller.addDocument(document)
            defer { controller.removeDocument(document) }
            session.beginEditing(.typing, text: text)
            let changed = !text.isEmpty
            checkEqual(controller.hasEditedDocuments, changed, "quit sees pending input [\(text)]")
            check(session.editing == nil, "pending editor is committed before quit decides [\(text)]")
            checkEqual(document.isDocumentEdited, changed, "dirty state matches pending input [\(text)]")
            checkEqual(document.undoManager?.groupingLevel, 0, "undo group closed synchronously [\(text)]")
            guard changed, document.undoManager?.groupingLevel == 0 else {
                check(document.undoManager?.canUndo == false, "unchanged input leaves no undo step")
                continue
            }
            checkEqual(session.sheet.cells[address]?.value, .text(text), "pending text is in the workbook")
            document.undoManager?.undo()
            check(!document.isDocumentEdited && document.undoManager?.canUndo == false, "one undo returns to clean")
        }
    }
}

/// 先记录系统真正读到的值，只对当前测试文档回答 false 以抑制保存框；不替换提交、撤销和 canClose。
@MainActor
private func observeCloseDirty(_ document: NSDocument, _ body: () -> Void) -> [Bool] {
    let selector = NSSelectorFromString("isDocumentEdited")
    let method = class_getInstanceMethod(NSDocument.self, selector)!
    let previous = method_getImplementation(method)
    typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
    let original = unsafeBitCast(previous, to: Getter.self)
    var queried: [Bool] = []
    let block: @convention(block) (AnyObject) -> Bool = { target in
        MainActor.assumeIsolated {
            let actual = original(target, selector)
            guard target === document else { return actual }
            queried.append(actual)
            return false
        }
    }
    let replacement = imp_implementationWithBlock(block)
    method_setImplementation(method, replacement)
    defer { method_setImplementation(method, previous); imp_removeBlock(replacement) }
    body()
    return queried
}

@MainActor
private final class CloseDecisionProbe: NSObject {
    var valueAtDecision: CellValue?
    var editingEnded = false
    @objc func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        let session = (document as? WorkbookDocument)?.session
        valueAtDecision = session?.sheet.cells[CellAddress(a1: "A1")!]?.value
        editingEnded = session?.editing == nil
    }
}
