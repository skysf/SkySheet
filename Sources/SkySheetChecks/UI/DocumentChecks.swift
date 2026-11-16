import AppKit
import ObjectiveC.runtime
import SkySheetCore

@MainActor
func closeDecisionChecks() {
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
