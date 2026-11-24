import Foundation
import Observation
import SkySheetCore
import SkySheetDisplay
import SkySheetFiles

@MainActor @Observable
final class MobileWorkbook {
    let url: URL
    let writer: WorkbookAutosave
    private(set) var workbook: Workbook
    private(set) var sheetIndex: Int
    private(set) var styles: StyleResolver
    private(set) var geometry: SheetGeometry
    private(set) var merges: MergeIndex
    private(set) var address = CellAddress(row: 0, column: 0)
    var input = ""
    var status = ""
    var problem: String?
    private var initialInput = ""
    private var latestEdit: UUID?
    private var origin: LoadedWorkbook
    var sheet: Sheet { workbook.sheets[sheetIndex] }

    init(url: URL, loaded: LoadedWorkbook, history: WorkbookHistory) throws {
        guard let index = loaded.workbook.sheets.firstIndex(where: { $0.visibility == .visible }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.url = url
        origin = loaded
        workbook = loaded.workbook
        sheetIndex = index
        writer = WorkbookAutosave(url: url, loaded: loaded, history: history)
        let resolver = StyleResolver(workbook: loaded.workbook)
        styles = resolver
        let sheet = loaded.workbook.sheets[index]
        geometry = SheetGeometry(sheet: sheet, baseFontSize: resolver.baseFontSize, zoom: 1.7)
        merges = MergeIndex(sheet.merges)
        select(address)
    }

    static func open(_ url: URL) async throws -> MobileWorkbook {
        let history = WorkbookHistory(file: url)
        let loaded = try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var error: NSError?
            var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { file in
                result = Result { try Data(contentsOf: file) }
            }
            if let error { throw error }
            return try LoadedWorkbook(data: result.get(), url: url, history: history)
        }.value
        return try MobileWorkbook(url: url, loaded: loaded, history: history)
    }

    func select(_ cell: CellAddress) {
        guard commit() else { return }
        address = merges.merge(containing: cell)?.start ?? cell
        _ = geometry.include(address)
        refreshInput()
    }

    func showSheet(_ index: Int) {
        guard index != sheetIndex, workbook.sheets.indices.contains(index), commit() else { return }
        sheetIndex = index
        resetGrid()
    }

    @discardableResult func commit() -> Bool {
        guard ExactText(input) != ExactText(initialInput) else { return true }
        var changed = workbook
        changed.enter(CellInput.parse(input, dateSystem: workbook.dateSystem), at: address, sheet: sheetIndex)
        if changed != workbook {
            if let locked = changed.finishEditing(since: workbook, author: .user, cache: origin.recalcCache) {
                problem = String(localized: "Only Excel can edit the formula at \(locked.cell.a1).")
                refreshInput()
                return false
            }
            if changed.styles != workbook.styles { styles = StyleResolver(workbook: changed) }
            workbook = changed
            submit(String(localized: "Edit \(sheet.name)!\(address.a1)"))
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
        workbook = restored.workbook
        styles = StyleResolver(workbook: workbook)
        sheetIndex = index
        resetGrid()
        submit(String(localized: "Restore \(version.title)"))
    }

    private func resetGrid() {
        geometry = SheetGeometry(sheet: sheet, baseFontSize: styles.baseFontSize, zoom: 1.7)
        merges = MergeIndex(sheet.merges)
        address = CellAddress(row: 0, column: 0)
        refreshInput()
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
                status = String(localized: "Couldn't save")
                problem = error.localizedDescription
            } else {
                status = String(localized: "Saved")
            }
        }
    }
}
