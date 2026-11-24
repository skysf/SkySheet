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
        // 部分文件提供方只报 public.data，能否读由所选文件的扩展名和实际解析共同确定。
        .fileImporter(isPresented: $picker, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url): open(url)
            case .failure(let error) where (error as? CocoaError)?.code == .userCancelled: break
            case .failure(let error): problem = error.localizedDescription
            }
        }
        .fileDialogDefaultDirectory(.documentsDirectory)
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
            .filter(Self.supports)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func supports(_ url: URL) -> Bool {
        ["xlsx", "csv", "tsv"].contains(url.pathExtension.lowercased())
    }

    private func open(_ url: URL, replacingEditor: Bool = false) {
        guard Self.supports(url) else {
            problem = String(localized: "Choose an Excel (.xlsx), CSV or TSV workbook.")
            return
        }
        guard replacingEditor || book?.finish() != false else { return }
        let request = UUID()
        let access = WorkbookFileAccess(url)
        opening = request
        Task {
            defer { if opening == request { opening = nil } }
            do {
                let loaded = try await MobileWorkbook.open(access)
                if opening == request { book = loaded }
            } catch { if opening == request { problem = error.localizedDescription } }
        }
    }
}
