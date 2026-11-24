import AppKit
import SkySheetCore
import SkySheetFiles

extension WorkbookDocument {
    func attachAutosave(url: URL, loaded: LoadedWorkbook, history: WorkbookHistory? = nil, backups: BackupStore = BackupStore()) {
        autosaveWriter = WorkbookAutosave(url: url, loaded: loaded, history: history ?? WorkbookHistory(file: url), backups: backups, presenter: self)
        latestEdit = nil
        lastSaveIssue = nil
        beforeUnconfirmedAI = nil
    }

    func saveStep(_ title: String, aiRound: UUID? = nil) {
        guard let session, let url = fileURL, var writer = autosaveWriter else { return }
        if url.standardizedFileURL != writer.url.standardizedFileURL {
            finishAutosave()
            writer = WorkbookAutosave(url: url, bytes: writer.lastFileBytes, format: csvFormat,
                                      history: WorkbookHistory(file: url), presenter: self)
            autosaveWriter = writer
        }
        let change = WorkbookAutosave.Change(title, workbook: session.workbook, source: source, baseline: baseline,
                                             writesOriginal: beforeUnconfirmedAI == nil, aiRound: aiRound)
        latestEdit = change.id
        session.saveStatus = String(localized: "Saving…")
        writer.submit(change) { [weak self] receipt in self?.accept(receipt) }
    }

    func finishAutosave() {
        guard latestEdit != nil, let receipt = autosaveWriter?.flush() else { return }
        accept(receipt)
    }

    private func accept(_ receipt: WorkbookAutosave.Receipt) {
        guard latestEdit == receipt.id else { return }
        lastSaveIssue = receipt.error
        if let error = receipt.error {
            session?.saveStatus = String(localized: "Couldn't save · \(error.localizedDescription)")
            if !isDocumentEdited { updateChangeCount(.changeDone) }
        } else if beforeUnconfirmedAI != nil {
            session?.saveStatus = String(localized: "Saved in history · ⌘S to apply AI edits")
            latestEdit = nil
        } else {
            fileModificationDate = receipt.modificationDate ?? fileModificationDate
            session?.saveStatus = String(localized: "Saved")
            backedUp = true
            latestEdit = nil
            updateChangeCount(.changeCleared)
            RecoveryCoordinator.shared.forget(self)
        }
    }

    @objc func showVersionHistory(_ sender: Any?) {
        session?.commitEditing(groupUndo: true)
        finishAutosave()
        guard let history = autosaveWriter?.history, let window = windowForSheet else { return }
        do {
            let versions = try history.versions()
            let panel = NSAlert()
            panel.messageText = String(localized: "Version History")
            guard !versions.isEmpty else {
                panel.informativeText = String(localized: "Versions appear here as you edit this workbook.")
                panel.beginSheetModal(for: window)
                return
            }
            let choices = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
            for (index, version) in versions.enumerated() {
                let title = WorkbookHistory.restoreLabel(at: index, in: versions)
                choices.menu?.addItem(withTitle: "\(version.date.formatted(date: .abbreviated, time: .standard))  ·  \(title)",
                                      action: nil, keyEquivalent: "")
            }
            choices.selectItem(at: min(1, versions.count - 1))
            panel.accessoryView = choices
            panel.informativeText = String(localized: "Restore a version as a new step. Later versions stay available.")
            panel.addButton(withTitle: String(localized: "Restore Version"))
            panel.addButton(withTitle: String(localized: "Cancel"))
            panel.beginSheetModal(for: window) { [weak self] answer in
                guard answer == .alertFirstButtonReturn, versions.indices.contains(choices.indexOfSelectedItem) else { return }
                do { try self?.restoreVersion(versions[choices.indexOfSelectedItem]) }
                catch { self?.presentError(error) }
            }
        } catch { presentError(error) }
    }

    func restoreVersion(_ version: WorkbookHistory.Version) throws {
        guard let session, let writer = autosaveWriter else { return }
        finishAutosave()
        let loaded = try writer.history.load(version)
        guard loaded.workbook.sheets.contains(where: { $0.visibility == .visible }) else { throw CocoaError(.fileReadCorruptFile) }
        session.editing = nil
        source = loaded.source
        baseline = loaded.workbook
        session.replaceWorkbook(loaded.workbook)
        session.resetSelection()
        undoManager?.removeAllActions()
        updateChangeCount(.changeDone)
        beforeUnconfirmedAI = nil
        saveStep(String(localized: "Restore \(version.title)"))
    }
}
