import AppKit
import SkySheetCore
import SkySheetFiles
import UniformTypeIdentifiers

/// 保存：设计第十节的六道保险里落在文档上的几道。
/// 1. 只有 ⌘S 写回原文件：autosavesInPlace 是 false，也不开自动保存。
/// 3. 先写临时文件（NSDocument 的安全保存），读回来核对（SaveVerifier / CSVWriter.verify），全对才替换原文件；
///    任何一步失败都报错，原文件不动。
/// 4. 第一次覆盖前备份原文件（BackupStore）；另存时盖掉一个已有的文件，也先备份它。
/// 5. 恢复副本见 RecoveryCoordinator。
/// 6. 文件在打开以后被别的程序改过：先问，可以另存为新文件、重新载入或者仍然覆盖。
/// 另外：csv 只能放一张表，有好几张 sheet 时先问是另存成 xlsx 还是只存当前这张。
extension WorkbookDocument {
    nonisolated static let xlsxType = "org.openxmlformats.spreadsheetml.sheet"
    nonisolated static let csvType = "public.comma-separated-values-text"
    nonisolated static let tsvType = "public.tab-separated-values-text"

    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        [Self.xlsxType, Self.csvType, Self.tsvType]
    }

    /// ⌘S，以及关窗口、退出时选「存」，都从这里进来。文件被别的程序改过就先问（第六道保险）：
    /// 要赶在 NSDocument 自己的检查之前，它那个提示只有「存 / 不存」两个选择（2026-10-08 实测）。
    override func save(withDelegate delegate: Any?, didSave didSaveSelector: Selector?,
                               contextInfo: UnsafeMutableRawPointer?) {
        session?.commitEditing()
        checkExternalChange { proceed in
            if proceed {
                super.save(withDelegate: delegate, didSave: didSaveSelector, contextInfo: contextInfo)
            } else {
                self.report(didSave: false, to: delegate, didSaveSelector, contextInfo)
            }
        }
    }

    /// 所有保存（⌘S、另存为、存副本）最后都走这里：csv 放不下好几张 sheet 先问，盖掉已有的文件先备份。
    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        session?.commitEditing()
        checkSheetsFitCSV(url, typeName) { proceed in
            guard proceed else { return completionHandler(CocoaError(.userCancelled)) }
            do {
                try self.backUpBeforeOverwriting(url, saveOperation)
            } catch {
                return completionHandler(error)
            }
            super.save(to: url, ofType: typeName, for: saveOperation) { error in
                self.finishSave(error, saveOperation)
                completionHandler(error)
            }
        }
    }

    /// 告诉调用方（关窗口、退出时的「存」）这次没存。回调的签名是 document:didSave:contextInfo:。
    private func report(didSave: Bool, to delegate: Any?, _ selector: Selector?, _ contextInfo: UnsafeMutableRawPointer?) {
        guard let delegate = delegate as? NSObject, let selector, delegate.responds(to: selector) else { return }
        typealias Callback = @convention(c) (NSObject, Selector, NSDocument, Bool, UnsafeMutableRawPointer?) -> Void
        unsafeBitCast(delegate.method(for: selector), to: Callback.self)(delegate, selector, self, didSave, contextInfo)
    }

    override func write(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                        originalContentsURL absoluteOriginalContentsURL: URL?) throws {
        // 没开异步写（canAsynchronouslyWrite 默认 false），NSDocument 在主线程上调它。
        try MainActor.assumeIsolated { try writeVerified(to: url, ofType: typeName) }
    }

    /// 写到 NSDocument 给的临时位置，再从磁盘读回来核对。核对过的结果先记着，存成功了才换上（finishSave）。
    @MainActor
    private func writeVerified(to url: URL, ofType typeName: String) throws {
        guard let session else { throw CocoaError(.fileWriteUnknown) }
        let workbook = session.workbook
        if DocumentLoader.isDelimitedText(typeName: typeName) {
            let format = typeName == fileType ? (csvFormat ?? Self.csvFormat(for: typeName)) : Self.csvFormat(for: typeName)
            let result = try CSVWriter.write(workbook.sheets[session.sheetIndex], styles: workbook.styles,
                                             dateSystem: workbook.dateSystem, format: format)
            try result.data.write(to: url)
            try CSVWriter.verify(try Data(contentsOf: url), written: result)
            pendingSave = (workbook, nil, format)
        } else {
            let result = try XLSXWriter.write(workbook, source: source, baseline: baseline)
            try result.data.write(to: url)
            let saved = try SaveVerifier.verify(try Data(contentsOf: url), written: result, workbook: workbook, source: source)
            pendingSave = (workbook, saved.source, nil)
        }
    }

    private static func csvFormat(for typeName: String) -> CSVFormat {
        var format = CSVFormat.standard
        if typeName == tsvType { format.delimiter = "\t" }
        return format
    }

    /// 存成功了：刚写的成为新的原包和基准，恢复副本不要了。「存一份副本」（saveTo）不改文档自己。
    private func finishSave(_ error: Error?, _ operation: NSDocument.SaveOperationType) {
        defer { pendingSave = nil }
        guard error == nil, let pending = pendingSave, operation == .saveOperation || operation == .saveAsOperation else {
            return
        }
        source = pending.source
        csvFormat = pending.csvFormat
        baseline = pending.workbook
        if operation == .saveAsOperation {
            // 另存出来的新文件是我们自己刚写的，不用再备份；以后存的就是它。
            backedUp = true
            recoveredFrom = nil
        }
        RecoveryCoordinator.shared.forget(self)
    }

    // MARK: - 第四道保险：备份

    private func backUpBeforeOverwriting(_ url: URL, _ operation: NSDocument.SaveOperationType) throws {
        guard [.saveOperation, .saveAsOperation, .saveToOperation].contains(operation),
              FileManager.default.fileExists(atPath: url.path) else { return }
        let isOriginal = operation == .saveOperation && fileURL?.standardizedFileURL == url.standardizedFileURL
        if isOriginal, backedUp { return }
        do {
            try BackupStore().backUp(url)
        } catch {
            throw SaveSafetyError.backupFailed(name: url.lastPathComponent, reason: error.localizedDescription)
        }
        if isOriginal { backedUp = true }
    }

    // MARK: - 第六道保险：文件被别的程序改过

    private func checkExternalChange(then next: @escaping (Bool) -> Void) {
        guard let fileURL, let known = fileModificationDate,
              let onDisk = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              abs(onDisk.timeIntervalSince(known)) > 0.001,
              let window = windowForSheet else { return next(true) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "“\(fileURL.lastPathComponent)” was changed by another app after you opened it.")
        alert.informativeText = String(localized: """
            Save As keeps both versions: yours goes to a new file. Overwrite replaces the other app's changes with yours \
            (SkySheet backs up the current file first). Reload discards your unsaved changes and shows the file as it is now.
            """)
        alert.addButton(withTitle: String(localized: "Save As…"))
        alert.addButton(withTitle: String(localized: "Overwrite"))
        alert.addButton(withTitle: String(localized: "Reload"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertSecondButtonReturn:
                // 仍然覆盖：先把别的程序改过的那一版也备份下来。NSDocument 自己的检查按新的修改时间算，不再拦。
                self.backedUp = false
                self.fileModificationDate = onDisk
                next(true)
            case .alertFirstButtonReturn:
                next(false)
                DispatchQueue.main.async { self.saveAs(nil) }
            case .alertThirdButtonReturn:
                next(false)
                DispatchQueue.main.async { self.reloadFromDisk() }
            default:
                next(false)
            }
        }
    }

    private func reloadFromDisk() {
        guard let fileURL, let fileType else { return }
        do {
            try revert(toContentsOf: fileURL, ofType: fileType)
        } catch {
            presentError(error)
        }
    }

    // MARK: - csv 只能放一张表

    private func checkSheetsFitCSV(_ url: URL, _ typeName: String, then next: @escaping (Bool) -> Void) {
        guard DocumentLoader.isDelimitedText(typeName: typeName), let session, session.workbook.sheets.count > 1,
              let window = windowForSheet else { return next(true) }
        let name = session.sheet.name
        let alert = NSAlert()
        alert.messageText = String(localized: "This workbook has \(session.workbook.sheets.count) sheets, but a .csv file holds only one.")
        alert.informativeText = String(localized: """
            Save as .xlsx keeps every sheet in a new file and leaves the .csv as it is. \
            Save Only “\(name)” writes just the sheet you're looking at; the other sheets aren't saved.
            """)
        alert.addButton(withTitle: String(localized: "Save as .xlsx…"))
        alert.addButton(withTitle: String(localized: "Save Only “\(name)”"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn:
                next(false)
                DispatchQueue.main.async { self.saveAsXLSX(near: url) }
            case .alertSecondButtonReturn:
                next(true)
            default:
                next(false)
            }
        }
    }

    /// 另存成 xlsx：默认放在原文件旁边、同名。
    private func saveAsXLSX(near url: URL) {
        guard let window = windowForSheet else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(Self.xlsxType) ?? .data]
        panel.directoryURL = url.deletingLastPathComponent()
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + ".xlsx"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let target = panel.url else { return }
            self.save(to: target, ofType: Self.xlsxType, for: .saveAsOperation) { error in
                if let error, (error as? CocoaError)?.code != .userCancelled { self.presentError(error) }
            }
        }
    }

    /// 从恢复副本打开的文档，存的时候默认放回原文件旁边。
    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        if let recoveredFrom {
            savePanel.directoryURL = recoveredFrom.deletingLastPathComponent()
            savePanel.nameFieldStringValue = recoveredFrom.deletingPathExtension().lastPathComponent
                + String(localized: " (Recovered)")
        }
        return true
    }
}

enum SaveSafetyError: LocalizedError {
    case backupFailed(name: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .backupFailed(let name, _):
            String(localized: "SkySheet couldn't back up “\(name)”, so it didn't save over it.")
        }
    }

    var failureReason: String? {
        switch self {
        case .backupFailed(_, let reason): reason
        }
    }
}

/// 存不了时给用户看的话。都发生在替换原文件之前：原文件没动。
extension XLSXWriteError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .strictFormat:
            String(localized: "SkySheet can't save changes into a Strict Open XML workbook yet. The file wasn't changed.")
        case .unreadablePart(let part):
            String(localized: "Part of the original file couldn't be read (\(part)), so SkySheet didn't save over it.")
        case .existingStylesChanged:
            String(localized: "SkySheet ran into an internal problem with cell styles and didn't save. The file wasn't changed.")
        case .zip:
            String(localized: "SkySheet couldn't put the file together. The file wasn't changed.")
        case .verificationFailed:
            String(localized: "The saved copy didn't match what's in the window, so the original file was left unchanged.")
        }
    }

    public var failureReason: String? {
        switch self {
        case .verificationFailed(let detail): detail
        case .zip(let error): "\(error)"
        default: nil
        }
    }
}

extension CSVWriteError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unencodableCharacter(let character):
            String(localized: "“\(String(character))” can't be written in this file's text encoding. The file wasn't changed.")
        case .verificationFailed:
            String(localized: "The saved copy didn't match what's in the window, so the original file was left unchanged.")
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .unencodableCharacter: String(localized: "Save it as .xlsx instead, or remove that character.")
        case .verificationFailed(let detail): detail
        }
    }
}
