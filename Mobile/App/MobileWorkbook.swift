import Foundation
import Observation
import UIKit
import SkySheetCore
import SkySheetDisplay
import SkySheetFiles

/// 在 Files 回调期间取得权限，后台读入、后续编辑和关窗按同一份文稿的生命周期配对。
final class WorkbookFileAccess: Sendable {
    let url: URL
    private let scoped: Bool

    init(_ url: URL) {
        self.url = url
        scoped = url.startAccessingSecurityScopedResource()
    }

    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
}

@MainActor @Observable
final class MobileWorkbook {
    private let access: WorkbookFileAccess
    var url: URL { access.url }
    let writer: WorkbookAutosave
    private(set) var workbook: Workbook
    private(set) var sheetIndex: Int
    private(set) var styles: StyleResolver
    private(set) var geometry: SheetGeometry
    private(set) var merges: MergeIndex
    private(set) var address = CellAddress(row: 0, column: 0)
    var input = "" {
        didSet { if picked != nil, ExactText(input) != ExactText(oldValue) { picked = nil } }
    }
    private(set) var picked: FormulaReferenceEdit?
    private var referenceOrigin: Int?
    var hasFormulaDraft: Bool {
        input.hasPrefix("=") && (picked != nil || referenceOrigin != nil || ExactText(input) != ExactText(initialInput))
    }
    var showingEditedCell: Bool { referenceOrigin == nil || referenceOrigin == sheetIndex }
    var pickedRange: CellRange? {
        guard let picked, picked.sheet.map({ $0 == sheet.name }) ?? showingEditedCell else { return nil }
        return picked.cells
    }
    var status = ""
    var problem: String?
    private(set) var externalConflict = false
    private(set) var canUndo = false
    private(set) var canRedo = false
    @ObservationIgnored private let undo = UndoManager()
    private var initialInput = ""
    private var latestEdit: UUID?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var origin: LoadedWorkbook
    var sheet: Sheet { workbook.sheets[sheetIndex] }

    init(access: WorkbookFileAccess, loaded: LoadedWorkbook, history: WorkbookHistory) throws {
        guard let index = loaded.workbook.sheets.firstIndex(where: { $0.visibility == .visible }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.access = access
        origin = loaded
        workbook = loaded.workbook
        sheetIndex = index
        writer = WorkbookAutosave(url: access.url, loaded: loaded, history: history)
        let resolver = StyleResolver(workbook: loaded.workbook)
        styles = resolver
        let sheet = loaded.workbook.sheets[index]
        geometry = SheetGeometry(sheet: sheet, baseFontSize: resolver.baseFontSize, zoom: 1.7)
        merges = MergeIndex(sheet.merges)
        undo.groupsByEvent = false
        select(address)
    }

    static func open(_ access: WorkbookFileAccess) async throws -> MobileWorkbook {
        let url = access.url
        let history = WorkbookHistory(file: url)
        let loaded = try await Task.detached(priority: .userInitiated) {
            var error: NSError?
            var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { file in
                result = Result { try Data(contentsOf: file) }
            }
            if let error { throw error }
            return try LoadedWorkbook(data: result.get(), url: url, history: history)
        }.value
        return try MobileWorkbook(access: access, loaded: loaded, history: history)
    }

    func select(_ cell: CellAddress) {
        let tappedSheet = sheetIndex
        guard commit() else { return }
        showSheet(tappedSheet)
        address = merges.merge(containing: cell)?.start ?? cell
        _ = geometry.include(address)
        refreshInput()
    }

    func showSheet(_ index: Int, pickingReference: Bool = false) {
        guard index != sheetIndex, workbook.sheets.indices.contains(index) else { return }
        if pickingReference {
            if referenceOrigin == nil { referenceOrigin = sheetIndex }
            sheetIndex = index
            resetGeometry()
            if showingEditedCell { _ = geometry.include(address) }
            return
        }
        guard commit() else { return }
        sheetIndex = index
        resetGrid()
    }

    func pick(_ range: CellRange, selection: NSRange) -> FormulaReferenceEdit? {
        let change = FormulaReferenceEdit.picking(range, sheet: showingEditedCell ? nil : sheet.name,
                                                  in: input, selection: selection, previous: picked)
        if let change { applyReference(change) }
        return change
    }

    func applyReference(_ change: FormulaReferenceEdit) {
        input = change.text
        picked = change
    }

    func cancelInput() {
        endReferenceSelection()
        refreshInput()
    }

    private func endReferenceSelection() {
        picked = nil
        if let index = referenceOrigin, index != sheetIndex {
            sheetIndex = index
            resetGeometry()
            _ = geometry.include(address)
        }
        referenceOrigin = nil
    }

    @discardableResult func commit() -> Bool {
        endReferenceSelection()
        guard ExactText(input) != ExactText(initialInput) else { return true }
        var changed = workbook
        changed.enter(CellInput.parse(input, dateSystem: workbook.dateSystem), at: address, sheet: sheetIndex)
        if changed != workbook {
            if let locked = changed.finishEditing(since: workbook, author: .user, cache: origin.recalcCache) {
                problem = String(localized: "Only Excel can edit the formula at \(locked.cell.a1).")
                refreshInput()
                return false
            }
            let title = String(localized: "Edit \(sheet.name)!\(address.a1)")
            undo.beginUndoGrouping()
            replace(changed, title: title)
            undo.endUndoGrouping()
            refreshUndo()
        }
        refreshInput()
        return true
    }

    func finish() -> Bool {
        guard commit() else { return false }
        if let receipt = writer.flush(), let error = receipt.error {
            problem = error.localizedDescription
            return false
        }
        return true
    }

    func finishInBackground() {
        guard commit(), latestEdit != nil, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Workbook autosave") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
        let writer = writer
        Task {
            _ = await Task.detached { writer.flush() }.value
            endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    func versions() throws -> [WorkbookHistory.Version] {
        guard commit() else { return [] }
        _ = writer.flush()
        return try writer.history.versions()
    }

    func saveLocalCopy() async throws -> URL {
        guard commit() else { throw CocoaError(.userCancelled) }
        let book = workbook, source = origin.source, baseline = origin.workbook
        let stem = url.deletingPathExtension().lastPathComponent
        return try await Task.detached(priority: .userInitiated) {
            let written = try XLSXWriter.write(book, source: source, baseline: baseline)
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temp) }
            try written.data.write(to: temp)
            let bytes = try Data(contentsOf: temp)
            _ = try SaveVerifier.verify(bytes, written: written, workbook: book, source: source)
            let documents = URL.documentsDirectory
            var number = 1
            while true {
                let suffix = number == 1 ? String(localized: "Copy") : String(localized: "Copy \(number)")
                let target = documents.appendingPathComponent("\(stem) (\(suffix)).xlsx")
                do { try NewFile.write(bytes, to: target); return target }
                catch is NewFile.AlreadyExists { number += 1 }
            }
        }.value
    }

    func restore(_ version: WorkbookHistory.Version) throws {
        let restored = try writer.history.load(version)
        guard let index = restored.workbook.sheets.firstIndex(where: { $0.visibility == .visible }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        origin = restored
        undo.removeAllActions()
        refreshUndo()
        workbook = restored.workbook
        styles = StyleResolver(workbook: workbook)
        sheetIndex = index
        resetGrid()
        submit(String(localized: "Restore \(version.title)"))
    }

    func stepBack() {
        guard commit(), undo.canUndo else { return }
        undo.undo()
        refreshUndo()
    }

    func stepForward() {
        guard commit(), undo.canRedo else { return }
        undo.redo()
        refreshUndo()
    }

    private func replace(_ next: Workbook, title: String) {
        let previous = workbook
        undo.registerUndo(withTarget: self) { book in
            MainActor.assumeIsolated { book.replace(previous, title: title) }
        }
        if next.styles != workbook.styles { styles = StyleResolver(workbook: next) }
        workbook = next
        let label = undo.isUndoing ? String(localized: "Undo \(title)") : undo.isRedoing ? String(localized: "Redo \(title)") : title
        refreshInput()
        submit(label)
    }

    private func refreshUndo() {
        canUndo = undo.canUndo
        canRedo = undo.canRedo
    }

    private func resetGrid() {
        resetGeometry()
        address = CellAddress(row: 0, column: 0)
        refreshInput()
    }

    private func resetGeometry() {
        geometry = SheetGeometry(sheet: sheet, baseFontSize: styles.baseFontSize, zoom: 1.7)
        merges = MergeIndex(sheet.merges)
    }

    private func refreshInput() {
        let cell = sheet.cells[address] ?? Cell()
        initialInput = CellInput.editingText(cell, styles: workbook.styles, dateSystem: workbook.dateSystem)
        input = initialInput
    }

    private func submit(_ title: String) {
        let change = WorkbookAutosave.Change(title, workbook: workbook, source: origin.source, baseline: origin.workbook)
        latestEdit = change.id
        status = String(localized: "Saving…")
        writer.submit(change) { [weak self] receipt in
            guard let self, latestEdit == receipt.id else { return }
            if let error = receipt.error {
                externalConflict = error is WorkbookAutosave.Issue
                status = String(localized: "Couldn't save")
                problem = error.localizedDescription
            } else {
                externalConflict = false
                latestEdit = nil
                status = String(localized: "Saved")
            }
        }
    }
}
