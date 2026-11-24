import AppKit

/// 退出整个 App 时，NSDocumentController 先问 `hasEditedDocuments`，再只对标脏的文档调 canClose。
/// 编辑框里只有待提交的字时文档还是干净的：不先提交就会不问一声就退出，字丢掉。
/// 2026-11-16 在本机跑过：⌘Q 走 terminate: → _shouldTerminate → 私有的 closeAll → hasEditedDocuments；
/// Dock 的「退出」、注销关机走 Apple 事件，在调 terminate: 之前就经 _shouldTerminate 问过它，
/// 公开的 reviewUnsavedDocuments 两条路都不经过。所以只能在这里先提交，并同步结束撤销分组（和关窗口的 canClose 同一个理由）。
/// 要成为 NSDocumentController.shared，得在任何地方碰 shared 之前建好（AppDelegate.applicationWillFinishLaunching）。
final class WorkbookDocumentController: NSDocumentController {
    override var hasEditedDocuments: Bool {
        for case let document as WorkbookDocument in documents {
            document.session?.commitEditing(groupUndo: true)
            document.finishAutosave()
        }
        return super.hasEditedDocuments
    }
}
