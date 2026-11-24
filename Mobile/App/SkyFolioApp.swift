import SwiftUI
import UniformTypeIdentifiers
import SkyFolioTheme
import SkySheetFiles

@main
struct SkyFolioApp: App {
    var body: some Scene { WindowGroup { WorkbookLibrary().tint(FolioTheme.accent.color) } }
}

struct WorkbookLibrary: View {
    @Environment(\.scenePhase) private var phase
    @State private var book: MobileWorkbook?
    @State private var localFiles: [URL] = []
    @State private var picker = false
    @State private var opening: UUID?
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Group {
                if let book {
                    WorkbookEditor(book: book, close: {
                        if book.finish() { self.book = nil; refresh() }
                    }, openDocument: { open($0, replacingEditor: true) })
                    .id(ObjectIdentifier(book))
                } else {
                    List {
                        Button { picker = true } label: {
                            Label(String(localized: "Open Workbook…"), systemImage: "folder")
                        }.accessibilityIdentifier("open-workbook")
                        if !localFiles.isEmpty {
                            Section(String(localized: "On This Device")) {
                                ForEach(localFiles, id: \.self) { url in
                                    Button { open(url) } label: {
                                        Label(url.lastPathComponent, systemImage: "tablecells")
                                    }.accessibilityIdentifier("file-\(url.lastPathComponent)")
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden).background(FolioTheme.paper.color)
                    .navigationTitle(String(localized: "SkyFolio"))
                }
            }
            .disabled(opening != nil)
            .overlay { if opening != nil { ProgressView(String(localized: "Opening…")).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        }
        .sheet(isPresented: $picker) {
            WorkbookPicker { url in
                picker = false
                if let url { open(url) }
            }
        }
        .onAppear { refresh() }
        .onOpenURL { url in if url.isFileURL { open(url) } }
        .onChange(of: phase) { _, next in
            if next == .background { book?.finishInBackground() }
            if next == .active, book == nil { refresh() }
        }
        .alert(String(localized: "Couldn't Open Workbook"), isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button(String(localized: "OK")) {}
        } message: { Text(problem ?? "") }
    }

    private func refresh() {
        localFiles = ((try? FileManager.default.contentsOfDirectory(at: .documentsDirectory, includingPropertiesForKeys: nil,
                                                                     options: [.skipsHiddenFiles])) ?? [])
            .filter { ["xlsx", "csv", "tsv"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func open(_ url: URL, replacingEditor: Bool = false) {
        guard replacingEditor || book?.finish() != false else { return }
        let request = UUID()
        opening = request
        Task {
            defer { if opening == request { opening = nil } }
            do {
                let loaded = try await MobileWorkbook.open(url)
                if opening == request { book = loaded }
            } catch { if opening == request { problem = error.localizedDescription } }
        }
    }
}

private struct WorkbookPicker: UIViewControllerRepresentable {
    let picked: (URL?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(picked) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let xlsx = UTType(importedAs: "org.openxmlformats.spreadsheetml.sheet", conformingTo: .spreadsheet)
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [xlsx, .commaSeparatedText, .tabSeparatedText], asCopy: false)
        picker.directoryURL = .documentsDirectory
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let picked: (URL?) -> Void
        init(_ picked: @escaping (URL?) -> Void) { self.picked = picked }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { picked(urls.first) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { picked(nil) }
    }
}
