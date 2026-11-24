import SwiftUI
import UIKit
import UniformTypeIdentifiers
import SkyFolioTheme

@main
final class SkyFolioApp: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = WorkbookScene.self
        return configuration
    }
}

final class WorkbookScene: UIResponder, UIWindowSceneDelegate, UIDocumentBrowserViewControllerDelegate {
    var window: UIWindow?
    private let browser = UIDocumentBrowserViewController(forOpening: [.data])
    private var editor: UIHostingController<AnyView>?
    private var book: MobileWorkbook?
    private var opening: UUID?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        browser.delegate = self
        browser.allowsPickingMultipleItems = false
        browser.allowsDocumentCreation = false
        window.tintColor = UIColor(FolioTheme.accent.color)
        window.rootViewController = browser
        self.window = window
        window.makeKeyAndVisible()
        if let url = options.urlContexts.first?.url { open(url) }
    }

    func documentBrowser(_ controller: UIDocumentBrowserViewController, didPickDocumentsAt urls: [URL]) {
        if let url = urls.first { open(url) }
    }

    func documentBrowser(_ controller: UIDocumentBrowserViewController, didImportDocumentAt source: URL, toDestinationURL url: URL) {
        open(url)
    }

    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        if let url = contexts.first?.url { open(url) }
    }

    func sceneDidEnterBackground(_ scene: UIScene) { book?.finishInBackground() }

    private func open(_ url: URL, replacingEditor: Bool = false) {
        guard url.isFileURL else { return }
        guard ["xlsx", "csv", "tsv"].contains(url.pathExtension.lowercased()) else {
            showProblem(String(localized: "Choose an Excel (.xlsx), CSV or TSV workbook."))
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
                if opening == request { show(loaded) }
            } catch {
                if opening == request { showProblem(error.localizedDescription) }
            }
        }
    }

    private func show(_ book: MobileWorkbook) {
        self.book = book
        let content = AnyView(NavigationStack {
            WorkbookEditor(book: book, close: { [weak self] in self?.close() },
                           openDocument: { [weak self] in self?.open($0, replacingEditor: true) })
        }.tint(FolioTheme.accent.color))
        if let editor { editor.rootView = content; return }
        let editor = UIHostingController(rootView: content)
        editor.modalPresentationStyle = .fullScreen
        self.editor = editor
        browser.present(editor, animated: true)
    }

    private func close() {
        guard book?.finish() != false else { return }
        opening = nil
        editor?.dismiss(animated: true)
        editor = nil
        book = nil
    }

    private func showProblem(_ message: String) {
        let alert = UIAlertController(title: String(localized: "Couldn't Open Workbook"), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        (browser.presentedViewController ?? browser).present(alert, animated: true)
    }
}
