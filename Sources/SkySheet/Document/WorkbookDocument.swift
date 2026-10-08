import AppKit
import SkySheetCore
import SkySheetDisplay
import SkySheetFiles

/// 一个打开的 xlsx / csv（设计 8.1 节）。文档层用 AppKit 的 NSDocument：SwiftUI 的 DocumentGroup 会自动把改动存回原文件，
/// 违反「只有 ⌘S 才写回」（设计第 15 条）。保存和六道保险在 WorkbookDocument+Saving.swift。
///
/// NSDocument 的 read / write 不在主线程隔离域里，但我们没开并发读写（canConcurrentlyReadDocuments、
/// canAsynchronouslyWrite 都是默认的 false），系统在主线程上调它们。下面几个 nonisolated(unsafe) 的属性都只在主线程上读写。
@objc(WorkbookDocument)
final class WorkbookDocument: NSDocument {
    nonisolated(unsafe) var loaded: DocumentLoader.Loaded?
    /// 窗口建好以后的编辑状态。保存时从这里拿工作簿。
    nonisolated(unsafe) var session: SheetSession?
    /// 原包：保存时没改过的部件照抄（设计 7.2 节）。打开的是 csv 时没有。
    nonisolated(unsafe) var source: XLSXSource?
    /// 打开（或上次保存）时的工作簿：判断哪张 sheet 改过。
    nonisolated(unsafe) var baseline: Workbook?
    /// 打开的是 csv 时原来的写法（编码、分隔符、换行）。
    nonisolated(unsafe) var csvFormat: CSVFormat?
    /// 刚写好、核对过、还没确认存成功的：存成功以后它们成为新的原包和基准。
    nonisolated(unsafe) var pendingSave: (workbook: Workbook, source: XLSXSource?, csvFormat: CSVFormat?)?
    /// 这次打开以后备份过原文件没有（第四道保险：第一次覆盖前备份）。
    var backedUp = false
    /// 恢复副本的编号和上次写恢复副本时的改动次数（第五道保险）。
    let recoveryID = UUID()
    var recoveredRevision: Int?
    /// 从恢复副本打开的：原来那个文件。存的时候默认存回它旁边。
    var recoveredFrom: URL?

    override class var autosavesInPlace: Bool { false }

    override func read(from url: URL, ofType typeName: String) throws {
        let loaded = try DocumentLoader.load(contentsOf: url, typeName: typeName)
        self.loaded = loaded
        source = loaded.source
        baseline = loaded.workbook
        csvFormat = loaded.csvFormat
    }

    override func makeWindowControllers() {
        guard let loaded else { return }
        let session = SheetSession(workbook: loaded.workbook)
        session.undoManager = undoManager
        self.session = session
        addWindowController(WorkbookWindowController(session: session))
    }

    /// 「复原到上次存的样子」和「文件被别的程序改了，重新载入」：读回来以后换掉窗口里的工作簿，撤销记录清空。
    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        try super.revert(toContentsOf: url, ofType: typeName)
        guard let loaded, let session else { return }
        session.editing = nil
        session.replaceWorkbook(loaded.workbook)
        session.resetSelection()
        undoManager?.removeAllActions()
        backedUp = false
    }

    override func close() {
        RecoveryCoordinator.shared.forget(self)
        super.close()
    }
}

/// 读文件、整本重算。App 打开文档和截图模式都走这里。
enum DocumentLoader {
    struct Loaded {
        var workbook: Workbook
        var source: XLSXSource?
        var csvFormat: CSVFormat?
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
            return Loaded(workbook: fitted, source: nil, csvFormat: csv.format)
        }
        var document = try XLSXReader.readDocument(data)
        // 读进来先整本重算一遍：TODAY() 是今天，我们算得了的公式用我们的结果，算不了的保留文件里的缓存值。
        Recalculator.recalculate(&document.workbook)
        return Loaded(workbook: document.workbook, source: document.source, csvFormat: nil)
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

    static func isDelimitedText(url: URL? = nil, typeName: String?) -> Bool {
        if let typeName, typeName.contains("separated-values") || typeName.contains("delimited") { return true }
        return ["csv", "tsv", "txt"].contains(url?.pathExtension.lowercased() ?? "")
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
