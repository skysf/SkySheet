import AppKit
import SkySheetCore
import SkySheetFiles

/// 第五道保险的恢复副本（保存排查第 8、9 条，2026-11-16）。只用临时目录里的 RecoveryStore，不碰真的恢复目录；
/// 不建窗口，文档只临时登记到 NSDocumentController 上（写恢复副本按它找文档），查完就拿掉。
@MainActor
func recoveryChecks() {
    let a1 = CellAddress(a1: "A1")!

    group("ui-30: a restored document keeps its recovery copy until a new one is written") {
        let folder = try makeTemporaryDirectory()
        let store = RecoveryStore(root: folder.appendingPathComponent("Recovery", isDirectory: true))
        var sheet = Sheet(id: 1, name: "Main")
        sheet.cells[a1] = Cell(value: .number(2))
        let entry = RecoveryStore.Entry(id: UUID(), originalPath: folder.appendingPathComponent("loan.xlsx").path,
                                        displayName: "loan.xlsx", savedAt: Date(timeIntervalSince1970: 1_790_000_000))
        try store.save(try XLSXWriter.write(Workbook(sheets: [sheet]), source: nil, baseline: nil).data, entry: entry)

        // 和 Restore 一样：读出恢复副本，接到文档上。还没轮到下一次写恢复副本就又崩了，下次启动还要能找到它。
        let coordinator = RecoveryCoordinator(store: store)
        let document = WorkbookDocument()
        try document.read(from: store.dataURL(entry.id), ofType: WorkbookDocument.xlsxType)
        coordinator.adopt(entry, into: document)
        defer { NSDocumentController.shared.removeDocument(document) }
        checkEqual(store.entries().map(\.id), [entry.id], "the copy is still there after restoring")

        // 正常往下走：下一轮写的新副本原地换掉旧的，不多出一份。
        guard let loaded = document.loaded else { fail("the recovery copy wasn't read"); return }
        document.session = SheetSession(workbook: loaded.workbook)
        document.updateChangeCount(.changeDone)
        coordinator.writeCopies()
        coordinator.drain()
        let entries = store.entries()
        checkEqual(entries.map(\.id), [entry.id], "the next copy replaces it in place")
        checkEqual(entries.first?.displayName, "loan (Recovered)", "under the restored document's name")
        checkEqual(try XLSXReader.read(Data(contentsOf: store.dataURL(entry.id))).sheets.first?.cells[a1]?.value,
                   .number(2), "with the restored content")
    }

    group("ui-31: a recovery copy that couldn't be written is tried again") {
        let folder = try makeTemporaryDirectory()
        // 恢复目录的位置先放一个同名文件：写恢复副本失败（和磁盘满、文件夹一时写不了一样）。
        let root = folder.appendingPathComponent("Recovery")
        try Data().write(to: root)
        let store = RecoveryStore(root: root)
        let coordinator = RecoveryCoordinator(store: store)
        let document = WorkbookDocument()
        document.session = SheetSession(workbook: Workbook(sheets: [Sheet(id: 1, name: "Main")]))
        NSDocumentController.shared.addDocument(document)
        defer { NSDocumentController.shared.removeDocument(document) }
        document.updateChangeCount(.changeDone)

        coordinator.writeCopies()
        coordinator.drain()
        checkEqual(store.entries().count, 0, "the first try fails")
        // 又能写了，文档没再改：同一版下一轮要再写。
        try FileManager.default.removeItem(at: root)
        coordinator.writeCopies()
        coordinator.drain()
        checkEqual(store.entries().map(\.id), [document.recoveryID], "the same revision is written on the next round")
        checkEqual(document.recoveredRevision, document.session?.revision, "and only now counts as written")
    }
}
