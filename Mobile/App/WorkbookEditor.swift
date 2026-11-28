import SwiftUI
import UIKit
import Observation
import SkySheetCore
import SkySheetFiles
import SkyFolioTheme

struct WorkbookEditor: View {
    @Bindable var book: MobileWorkbook
    let close: () -> Void
    let openDocument: (URL) -> Void
    @State private var typing = false
    @State private var formulaSelection = MobileFormulaSelection()
    @State private var position = ScrollPosition()
    @State private var viewport = CGRect(x: 0, y: 0, width: 700, height: 900)
    @State private var resultScroll: (sheet: Int, point: CGPoint)?
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
                MobileFormulaField(text: $book.input, focused: $typing, selection: formulaSelection) { _ = book.commit() }
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity)
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
            WorkbookGrid(book: book, position: $position, viewport: $viewport, picking: canPick, tap: tapCell, pickRange: pickRange)
                .id(book.sheetIndex)
            HStack {
                Menu {
                    ForEach(book.workbook.sheets.indices, id: \.self) { index in
                        if book.workbook.sheets[index].visibility == .visible {
                            Button(book.workbook.sheets[index].name) {
                                let picking = canPick
                                if picking, book.showingEditedCell, index != book.sheetIndex {
                                    let rect = book.geometry.rect(of: CellRange(book.address))
                                    let visible = CGRect(origin: viewport.origin, size: CGSize(width: viewport.width - WorkbookGrid.gutter,
                                                                                              height: viewport.height - WorkbookGrid.header))
                                    resultScroll = (book.sheetIndex, visible.contains(rect) ? viewport.origin : rect.origin)
                                }
                                book.showSheet(index, pickingReference: picking)
                                typing = picking
                            }
                        }
                    }
                } label: { Label(book.sheet.name, systemImage: "tablecells") }
                .accessibilityIdentifier("sheet-picker")
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
        .onChange(of: book.sheetIndex) { _, index in
            // 跨表提交或取消后回到原结果格所在的画面，即使它在大表的很远处。
            if let saved = resultScroll, saved.sheet == index {
                position.scrollTo(point: saved.point)
                resultScroll = nil
            } else {
                position.scrollTo(point: .zero)
                if !book.hasFormulaDraft { resultScroll = nil }
            }
        }
        // 系统页签菜单可以暂时拿走键盘焦点，仍在等引用的草稿要留给下一次点选。
        .onChange(of: typing) { _, active in if !active && !canPick { _ = book.commit() } }
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
        formulaSelection.range(in: book.input) ?? book.picked?.caret ?? NSRange(location: book.input.utf16.count, length: 0)
    }

    private var canPick: Bool {
        (typing || book.hasFormulaDraft) && FormulaReferenceEdit.slot(in: book.input, selection: caret, previous: book.picked) != nil
    }

    private func tapCell(_ cell: CellAddress) {
        if canPick { pickRange(CellRange(cell)) }
        else { book.select(cell); typing = false }
    }

    private func pickRange(_ range: CellRange) {
        if let change = book.pick(range, selection: caret) { placeCaret(after: change) }
    }

    private func placeCaret(after change: FormulaReferenceEdit) {
        typing = true
        formulaSelection.display(change)
    }
}

/// 用系统文本框自己的 UTF-16 光标。旧格的 String.Index 无法用于新格的字符串，特别是从有值的格子切到空格时。
@MainActor @Observable
private final class MobileFormulaSelection {
    @ObservationIgnored weak var field: UITextField?
    private var source = ExactText("")
    private var selected: NSRange?

    func capture(_ field: UITextField) {
        guard let range = field.selectedTextRange else { selected = nil; return }
        let text = field.text ?? ""
        let start = field.offset(from: field.beginningOfDocument, to: range.start)
        let end = field.offset(from: field.beginningOfDocument, to: range.end)
        guard start >= 0, end >= start, end <= text.utf16.count else { selected = nil; return }
        source = ExactText(text)
        selected = NSRange(location: start, length: end - start)
    }

    func range(in text: String) -> NSRange? {
        guard source == ExactText(text), let selected, Range(selected, in: text) != nil else { return nil }
        return selected
    }

    func display(_ change: FormulaReferenceEdit) {
        guard let field else { return }
        field.text = change.text
        if !field.isFirstResponder { field.becomeFirstResponder() }
        if let caret = field.position(from: field.beginningOfDocument, offset: change.caret.location) {
            field.selectedTextRange = field.textRange(from: caret, to: caret)
        }
        capture(field)
    }
}

private struct MobileFormulaField: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let selection: MobileFormulaSelection
    let commit: () -> Void

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = String(localized: "Value or formula")
        field.accessibilityIdentifier = "formula-input"
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.spellCheckingType = .no
        field.returnKeyType = .done
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        selection.field = field
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        context.coordinator.refreshing = true
        defer { context.coordinator.refreshing = false }
        if field.markedTextRange == nil, ExactText(field.text ?? "") != ExactText(text) { field.text = text }
        if focused, !field.isFirstResponder, field.window != nil { field.becomeFirstResponder() }
        if !focused, field.isFirstResponder { field.resignFirstResponder() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: MobileFormulaField
        var refreshing = false
        init(_ parent: MobileFormulaField) { self.parent = parent }

        @objc func changed(_ field: UITextField) {
            parent.text = field.text ?? ""
            parent.selection.capture(field)
        }

        func textFieldDidChangeSelection(_ field: UITextField) {
            if !refreshing, field.isFirstResponder { parent.selection.capture(field) }
        }

        func textFieldDidBeginEditing(_ field: UITextField) {
            if !refreshing { parent.focused = true; parent.selection.capture(field) }
        }

        func textFieldDidEndEditing(_ field: UITextField) {
            if !refreshing { parent.focused = false }
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            parent.commit()
            parent.focused = false
            field.resignFirstResponder()
            return false
        }
    }
}
