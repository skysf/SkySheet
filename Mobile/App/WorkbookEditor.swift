import SwiftUI
import SkySheetCore
import SkySheetFiles
import SkyFolioTheme

struct WorkbookEditor: View {
    @Bindable var book: MobileWorkbook
    let close: () -> Void
    let openDocument: (URL) -> Void
    @FocusState private var typing: Bool
    @State private var textSelection: TextSelection?
    @State private var position = ScrollPosition()
    @State private var choosingAddress = false
    @State private var addressInput = ""
    @State private var history: HistoryList?
    @State private var copying = false

    private struct HistoryList: Identifiable {
        let id = UUID()
        let versions: [WorkbookHistory.Version]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(book.address.a1) { addressInput = book.address.a1; choosingAddress = true }
                    .font(.callout.monospaced().weight(.semibold)).accessibilityIdentifier("address")
                Divider().frame(height: 24)
                TextField(String(localized: "Value or formula"), text: $book.input, selection: $textSelection)
                    .focused($typing).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.done).onSubmit { _ = book.commit(); typing = false }
                    .accessibilityIdentifier("formula-input")
                if typing, book.input.hasPrefix("=") {
                    Button {
                        if let change = FormulaReferenceEdit.cyclingAnchors(in: book.input, selection: caret) {
                            book.applyReference(change)
                            placeCaret(after: change)
                        }
                    } label: { Text(verbatim: "$") }
                    .accessibilityLabel(String(localized: "Cycle Reference Type"))
                    Button { book.cancelInput(); typing = false } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(String(localized: "Cancel Formula"))
                }
            }.padding(.horizontal, 14).frame(minHeight: 48).background(FolioTheme.paper.color)
            WorkbookGrid(book: book, position: $position, picking: canPick, tap: tapCell, pickRange: pickRange).id(book.sheetIndex)
            HStack {
                Menu {
                    ForEach(book.workbook.sheets.indices, id: \.self) { index in
                        if book.workbook.sheets[index].visibility == .visible {
                            Button(book.workbook.sheets[index].name) {
                                let picking = canPick
                                book.showSheet(index, pickingReference: picking)
                                typing = picking
                            }
                        }
                    }
                } label: { Label(book.sheet.name, systemImage: "tablecells") }
                Spacer()
                Text(book.status).font(.caption).foregroundStyle(FolioTheme.secondaryInk.color).accessibilityIdentifier("save-status")
            }.padding(.horizontal, 14).frame(minHeight: 44).background(FolioTheme.header.color)
        }
        .navigationTitle(book.url.lastPathComponent).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { typing = false; close() } label: { Label(String(localized: "Files"), systemImage: "chevron.backward") }
                    .accessibilityIdentifier("close-workbook")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { book.stepBack() } label: { Label(String(localized: "Undo"), systemImage: "arrow.uturn.backward") }
                        .disabled(!book.canUndo)
                    Button { book.stepForward() } label: { Label(String(localized: "Redo"), systemImage: "arrow.uturn.forward") }
                        .disabled(!book.canRedo)
                    Button { showHistory() } label: { Label(String(localized: "Version History"), systemImage: "clock.arrow.circlepath") }
                    if book.externalConflict {
                        Button { if book.commit() { _ = book.writer.flush(); openDocument(book.url) } } label: {
                            Label(String(localized: "Reload File from Disk"), systemImage: "arrow.clockwise")
                        }
                    }
                    Button {
                        copying = true
                        Task {
                            defer { copying = false }
                            do { openDocument(try await book.saveLocalCopy()) } catch { book.problem = error.localizedDescription }
                        }
                    } label: { Label(String(localized: "Save Excel Copy on This Device"), systemImage: "doc.on.doc") }
                } label: { Label(String(localized: "Workbook Options"), systemImage: "ellipsis.circle") }
                .accessibilityIdentifier("workbook-options")
            }
        }
        .disabled(copying)
        .onChange(of: book.sheetIndex) { _, _ in position.scrollTo(point: .zero) }
        .onChange(of: typing) { _, active in if !active { _ = book.commit() } }
        .alert(String(localized: "Go to Cell"), isPresented: $choosingAddress) {
            TextField(String(localized: "Cell address"), text: $addressInput).textInputAutocapitalization(.characters)
            Button(String(localized: "Go")) {
                if let cell = CellAddress(a1: addressInput) {
                    book.select(cell)
                    position.scrollTo(point: CGPoint(x: book.geometry.x(ofColumn: cell.column), y: book.geometry.y(ofRow: cell.row)))
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        }
        .alert(String(localized: "Workbook"), isPresented: Binding(get: { book.problem != nil }, set: { if !$0 { book.problem = nil } })) {
            Button(String(localized: "OK")) {}
        } message: { Text(book.problem ?? "") }
        .sheet(item: $history) { selection in
            NavigationStack {
                List(selection.versions) { version in
                    Button {
                        do { try book.restore(version) } catch { book.problem = error.localizedDescription }
                        history = nil
                    } label: {
                        VStack(alignment: .leading) {
                            Text(version.title)
                            Text(version.date.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel(String(localized: "Restore \(version.title)"))
                }
                .overlay { if selection.versions.isEmpty { Text(String(localized: "Versions appear here as you edit.")) } }
                .navigationTitle(String(localized: "Version History"))
                .toolbar { Button(String(localized: "Done")) { history = nil } }
            }.presentationDetents([.medium, .large])
        }
    }

    private func showHistory() {
        typing = false
        do { history = HistoryList(versions: try book.versions()) }
        catch { book.problem = error.localizedDescription }
    }

    private var caret: NSRange {
        if case .selection(let range) = textSelection?.indices,
           range.lowerBound >= book.input.startIndex, range.upperBound <= book.input.endIndex {
            return NSRange(range, in: book.input)
        }
        return book.picked?.caret ?? NSRange(location: book.input.utf16.count, length: 0)
    }

    private var canPick: Bool {
        typing && FormulaReferenceEdit.slot(in: book.input, selection: caret, previous: book.picked) != nil
    }

    private func tapCell(_ cell: CellAddress) {
        if canPick { pickRange(CellRange(cell)) }
        else { book.select(cell); typing = false }
    }

    private func pickRange(_ range: CellRange) {
        if let change = book.pick(range, selection: caret) { placeCaret(after: change) }
    }

    private func placeCaret(after change: FormulaReferenceEdit) {
        if let range = Range(change.caret, in: book.input) { textSelection = TextSelection(insertionPoint: range.lowerBound) }
    }
}
