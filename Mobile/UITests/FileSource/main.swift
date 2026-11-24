import UIKit

/// 通过系统的“存储到文件”创建外部文稿，模拟从另一个 App 导出工作表。
final class ExportSample: UIViewController, UIDocumentPickerDelegate {
    private let button = UIButton(type: .system)
    private let sample = FileManager.default.temporaryDirectory.appendingPathComponent("Exported Workbook.csv")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        button.setTitle("Export Sample", for: .normal)
        button.accessibilityIdentifier = "export-sample"
        button.addTarget(self, action: #selector(exportSample), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)
        NSLayoutConstraint.activate([button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                                     button.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        do {
            try Data("31,93\n".utf8).write(to: sample)
            try Data("Fixture folder".utf8).write(to: URL.documentsDirectory.appendingPathComponent("Location.txt"))
        } catch { fatalError("Could not prepare sample: \(error)") }
    }

    @objc private func exportSample() {
        let picker = UIDocumentPickerViewController(forExporting: [sample], asCopy: true)
        picker.directoryURL = URL.documentsDirectory
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        button.setTitle(urls.isEmpty ? "No exported document" : "Exported", for: .normal)
    }
}

final class FileSource: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = ExportSample()
        self.window = window
        window.makeKeyAndVisible()
        return true
    }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(FileSource.self))
