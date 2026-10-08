import AppKit
import SkySheetCore
import SkySheetDisplay
import SkySheetFiles

/// 一个打开的 xlsx / csv（设计 8.1 节）。文档层用 AppKit 的 NSDocument：SwiftUI 的 DocumentGroup 会自动把改动存回原文件，
/// 违反「只有 ⌘S 才写回」（设计第 15 条）。
///
/// M2 只看不改：Info.plist 里文档的角色是 Viewer，没有保存。M3 改成 Editor 并接上保存的六道保险（设计第十节）。
@objc(WorkbookDocument)
final class WorkbookDocument: NSDocument {
    /// NSDocument 的 read 不在主线程隔离域里，但我们没开并发读取（canConcurrentlyReadDocuments 默认是 false），
    /// 系统是在主线程上调它的，写这个属性和之后 makeWindowControllers 读它都在主线程。
    nonisolated(unsafe) private var loaded: DocumentLoader.Loaded?

    override class var autosavesInPlace: Bool { false }

    override func read(from url: URL, ofType typeName: String) throws {
        loaded = try DocumentLoader.load(contentsOf: url, typeName: typeName)
    }

    override func makeWindowControllers() {
        guard let loaded else { return }
        addWindowController(WorkbookWindowController(session: SheetSession(workbook: loaded.workbook)))
    }
}

/// 读文件、整本重算。App 打开文档和截图模式都走这里。
enum DocumentLoader {
    struct Loaded {
        var workbook: Workbook
        /// 打开的是 csv 时原来的编码、分隔符：M3 写回 csv 要用。
        var csv: CSVDocument?
    }

    static func load(contentsOf url: URL, typeName: String? = nil) throws -> Loaded {
        let data = try Data(contentsOf: url)
        if isDelimitedText(url: url, typeName: typeName) {
            let csv = try CSVReader.read(data, sheetName: url.deletingPathExtension().lastPathComponent)
            var workbook = csv.workbook
            Recalculator.recalculate(&workbook)
            // NSDocument 的 read 不在主线程隔离域里，但实际在主线程上调（WorkbookDocument 的说明）；截图模式也在主线程。
            // 量字体要在主线程：assumeIsolated 把这个前提写明，万一不在主线程会当场报错，而不是悄悄出问题。
            let fitted = MainActor.assumeIsolated { () -> Workbook in
                var copy = workbook
                autoFitColumns(&copy)
                return copy
            }
            return Loaded(workbook: fitted, csv: csv)
        }
        var workbook = try XLSXReader.read(data)
        // 读进来先整本重算一遍：TODAY() 是今天，我们算得了的公式用我们的结果，算不了的保留文件里的缓存值。
        Recalculator.recalculate(&workbook)
        return Loaded(workbook: workbook, csv: nil)
    }

    /// csv 没有列宽：按内容定宽（设计 7.3 节，AutoFit 的说明）。量文字要用真正画的字体，所以在 App 这一层做。
    @MainActor
    private static func autoFitColumns(_ workbook: inout Workbook) {
        let styles = StyleResolver(workbook: workbook)
        let fonts = FontBook()
        for index in workbook.sheets.indices {
            workbook.sheets[index].columns = AutoFit.columns(
                for: workbook.sheets[index], styles: styles, dateSystem: workbook.dateSystem,
                digitWidth: fonts.digitWidth(styles.style(0).font), measure: { fonts.width(of: $0, style: $1) })
        }
    }

    private static func isDelimitedText(url: URL, typeName: String?) -> Bool {
        if let typeName, typeName.contains("separated-values") || typeName.contains("delimited") { return true }
        return ["csv", "tsv", "txt"].contains(url.pathExtension.lowercased())
    }
}

/// 打不开时给用户看的话（界面只用英文，设计第 22 条）。
extension XLSXError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .passwordProtected:
            String(localized: "This workbook is password-protected. SkySheet can't open protected files yet.")
        case .legacyExcelFormat:
            String(localized: "This is an old-style .xls file. SkySheet opens .xlsx and .csv files; save it as .xlsx first.")
        case .zip, .missingPart, .malformedXML:
            String(localized: "This file is damaged or isn't an .xlsx workbook.")
        }
    }

    public var failureReason: String? {
        switch self {
        case .zip(let error): "\(error)"
        case .missingPart(let part): "Missing part: \(part)"
        case .malformedXML(let part, let line, let reason): "\(part), line \(line): \(reason)"
        case .passwordProtected, .legacyExcelFormat: nil
        }
    }
}

extension CSVError: LocalizedError {
    public var errorDescription: String? {
        String(localized: "SkySheet couldn't read the text in this file. It reads UTF-8, UTF-16 and GB18030 (GBK).")
    }
}
