import AppKit
import SkySheetCore
import SkySheetFiles

/// 第五道保险（设计第十节）：每 30 秒给有没保存改动的文档写一份恢复副本（RecoveryStore），文档存了或者关了就删掉。
/// 启动时还在的，说明上次没正常退出，问用户要不要恢复。恢复出来的文档是「未命名」的新窗口，原文件不动。
@MainActor
final class RecoveryCoordinator {
    static let shared = RecoveryCoordinator()

    private let store = RecoveryStore()
    /// 写和删排在同一条串行队列上：先写后删的顺序不会乱（乱了会留下一份不该有的恢复副本）。
    private let queue = DispatchQueue(label: "ai.skylu.skysheet.recovery", qos: .utility)
    private var timer: Timer?

    func start() {
        offerRestore()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { RecoveryCoordinator.shared.writeCopies() }
        }
    }

    /// 改过、而且自上次写过以后又改了的文档，各写一份。写 xlsx 放在后台，不卡界面。
    func writeCopies() {
        for case let document as WorkbookDocument in NSDocumentController.shared.documents {
            guard let session = document.session else { continue }
            guard document.isDocumentEdited else {
                if document.recoveredRevision != nil { forget(document) }
                continue
            }
            guard document.recoveredRevision != session.revision else { continue }
            document.recoveredRevision = session.revision
            let workbook = session.workbook
            let source = document.source
            let baseline = document.baseline
            let entry = RecoveryStore.Entry(id: document.recoveryID,
                                            originalPath: (document.fileURL ?? document.recoveredFrom)?.path,
                                            displayName: document.displayName, savedAt: Date())
            let store = self.store
            queue.async {
                guard let result = try? XLSXWriter.write(workbook, source: source, baseline: baseline) else { return }
                try? store.save(result.data, entry: entry)
            }
        }
    }

    /// 文档存了、关了：它的恢复副本不要了。
    func forget(_ document: WorkbookDocument) {
        document.recoveredRevision = nil
        let id = document.recoveryID
        let store = self.store
        queue.async { store.remove(id) }
    }

    /// 退出前等队列做完：删恢复副本的事要是没做完，下次启动会多问一次。
    func drain() {
        queue.sync {}
    }

    private func offerRestore() {
        let entries = store.entries()
        guard !entries.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = entries.count == 1
            ? String(localized: "SkySheet quit before “\(entries[0].displayName)” was saved.")
            : String(localized: "SkySheet quit before \(entries.count) documents were saved.")
        alert.informativeText = String(localized: """
            Restore the unsaved changes? Restored documents open in new windows; the original files haven't been changed.
            """)
        alert.addButton(withTitle: String(localized: "Restore"))
        alert.addButton(withTitle: String(localized: "Not Now"))
        alert.addButton(withTitle: String(localized: "Discard"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: entries.forEach(restore)
        case .alertThirdButtonReturn: entries.forEach { store.remove($0.id) }
        default: break
        }
    }

    private func restore(_ entry: RecoveryStore.Entry) {
        do {
            let controller = NSDocumentController.shared
            guard let document = try controller.makeDocument(withContentsOf: store.dataURL(entry.id),
                                                             ofType: WorkbookDocument.xlsxType) as? WorkbookDocument
            else { return }
            document.fileURL = nil
            document.recoveredFrom = entry.originalPath.map { URL(fileURLWithPath: $0) }
            let name = (entry.displayName as NSString).deletingPathExtension
            document.displayName = name + String(localized: " (Recovered)")
            controller.addDocument(document)
            document.makeWindowControllers()
            document.showWindows()
            document.updateChangeCount(.changeDone)
            store.remove(entry.id)
        } catch {
            NSApp.presentError(error)
        }
    }
}
