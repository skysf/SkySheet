import AppKit
import os
import SkySheetCore
import SkySheetFiles

/// 第五道保险（设计第十节）：每 30 秒给有没保存改动的文档写一份恢复副本（RecoveryStore），文档存了或者关了就删掉。
/// 启动时还在的，说明上次没正常退出，问用户要不要恢复。恢复出来的文档是「未命名」的新窗口，原文件不动。
@MainActor
final class RecoveryCoordinator {
    static let shared = RecoveryCoordinator()

    private let store: RecoveryStore
    /// 写和删排在同一条串行队列上：先写后删的顺序不会乱（乱了会留下一份不该有的恢复副本）。
    private let queue = DispatchQueue(label: "ai.skylu.skysheet.recovery", qos: .utility)
    /// 后台写完的恢复副本：哪份文档（恢复编号）、哪一版、写成没有。回到主线程后（下一轮开始前、drain）记到文档上。
    private let finished = OSAllocatedUnfairLock<[(id: UUID, revision: Int, saved: Bool)]>(initialState: [])
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    /// 启动时就在的恢复副本：只有它们是上次没正常退出留下的。
    private var leftAtLaunch: Set<UUID> = []

    /// 自检用临时目录里的 store；App 用默认的恢复目录。
    init(store: RecoveryStore = RecoveryStore()) {
        self.store = store
    }

    /// 被 AI 拉起来以后，用户第一次切到 SkySheet：这时再问要不要恢复。
    private func userArrived() {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        offerRestore()
    }

    /// `askNow` 为假（App 是被 AI 在后台拉起来的）：等用户自己切到 SkySheet 再问，没人看着时弹框会把 AI 的调用挂住。
    /// 问的只是启动时就在的那些（上次没正常退出留下的）：这次运行里每 30 秒写的恢复副本属于开着的文档，不能当成要恢复的
    /// （2026-10-09 端到端时抓到：被 AI 拉起来、过了一会儿用户切过来，问的是正开着的那个文档）。
    func start(askNow: Bool = true) {
        leftAtLaunch = Set(store.entries().map(\.id))
        if askNow {
            offerRestore()
        } else {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { RecoveryCoordinator.shared.userArrived() }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { RecoveryCoordinator.shared.writeCopies() }
        }
    }

    /// 改过、而且自上次写好以后又改了的文档，各写一份。写 xlsx 放在后台，不卡界面。
    /// 写好了才记下这一版：以前排上队就记，写失败了（磁盘满、文件夹一时写不了）这一版就再也不写了（保存排查第 9 条，2026-11-16）。
    func writeCopies() {
        noteFinishedWrites()
        for case let document as WorkbookDocument in NSDocumentController.shared.documents {
            guard let session = document.session else { continue }
            guard document.isDocumentEdited else {
                if document.recoveredRevision != nil || document.recoveringRevision != nil { forget(document) }
                continue
            }
            let revision = session.revision
            // 写好了的这一版不再写，正在写的也不再排一次；没写成的（recoveringRevision 已经放开）这一轮重写。
            guard document.recoveredRevision != revision, document.recoveringRevision != revision else { continue }
            document.recoveringRevision = revision
            let workbook = session.workbook
            let source = document.source
            let baseline = document.baseline
            let entry = RecoveryStore.Entry(id: document.recoveryID,
                                            originalPath: (document.fileURL ?? document.recoveredFrom)?.path,
                                            displayName: document.displayName, savedAt: Date())
            let store = self.store
            let finished = self.finished
            queue.async {
                let saved = (try? XLSXWriter.write(workbook, source: source, baseline: baseline))
                    .map { (try? store.save($0.data, entry: entry)) != nil } ?? false
                finished.withLock { $0.append((entry.id, revision, saved)) }
            }
        }
    }

    /// 后台写完的结果记到文档上：写成的那一版才算写好；没写成的放开，下一轮再写。文档已经存了、关了（forget 过）
    /// 或者又排了新的一版，这个结果就不算数。
    private func noteFinishedWrites() {
        let results = finished.withLock { list -> [(id: UUID, revision: Int, saved: Bool)] in
            defer { list.removeAll() }
            return list
        }
        guard !results.isEmpty else { return }
        let documents = NSDocumentController.shared.documents.compactMap { $0 as? WorkbookDocument }
        for result in results {
            guard let document = documents.first(where: { $0.recoveryID == result.id }),
                  document.recoveringRevision == result.revision else { continue }
            document.recoveringRevision = nil
            if result.saved { document.recoveredRevision = result.revision }
        }
    }

    /// 文档存了、关了：它的恢复副本不要了。
    func forget(_ document: WorkbookDocument) {
        document.recoveredRevision = nil
        document.recoveringRevision = nil
        let id = document.recoveryID
        let store = self.store
        queue.async { store.remove(id) }
    }

    /// 退出前等队列做完：删恢复副本的事要是没做完，下次启动会多问一次。
    func drain() {
        queue.sync {}
        noteFinishedWrites()
    }

    func offerRestore() {
        let open = Set(NSDocumentController.shared.documents.compactMap { ($0 as? WorkbookDocument)?.recoveryID })
        let entries = store.entries().filter { leftAtLaunch.contains($0.id) && !open.contains($0.id) }
        leftAtLaunch = []
        guard !entries.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = entries.count == 1
            ? String(localized: "SkyFolio quit before “\(entries[0].displayName)” was saved.")
            : String(localized: "SkyFolio quit before \(entries.count) documents were saved.")
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
            guard let document = try NSDocumentController.shared.makeDocument(
                withContentsOf: store.dataURL(entry.id), ofType: WorkbookDocument.xlsxType) as? WorkbookDocument
            else { return }
            adopt(entry, into: document)
            document.makeWindowControllers()
            document.showWindows()
            document.updateChangeCount(.changeDone)
        } catch {
            NSApp.presentError(error)
        }
    }

    /// 从恢复副本读出来的文档变成「（Recovered）」的未命名文档。旧副本不删：文档接着用它的恢复编号，下一轮写恢复副本时
    /// 原地换成新的（原子写，换的那一下也不会两份都没有）；存了、关了才删（forget）。以前恢复完马上删，新副本写好之前再崩一次，
    /// 恢复出来的改动就没了（保存排查第 8 条，2026-11-16）。
    func adopt(_ entry: RecoveryStore.Entry, into document: WorkbookDocument) {
        document.fileURL = nil
        document.recoveredFrom = entry.originalPath.map { URL(fileURLWithPath: $0) }
        let name = (entry.displayName as NSString).deletingPathExtension
        document.displayName = name + String(localized: " (Recovered)")
        document.recoveryID = entry.id
        NSDocumentController.shared.addDocument(document)
    }
}
