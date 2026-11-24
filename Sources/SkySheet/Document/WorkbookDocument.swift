import AppKit
import SkySheetCore
import SkySheetDisplay
import SkySheetFiles

/// 一个打开的 xlsx / csv。编辑按步骤自动保存；NSDocument 负责打开、另存、窗口和系统撤销。
///
/// NSDocument 的 read / write 不在主线程隔离域里，但我们没开并发读写（canConcurrentlyReadDocuments、
/// canAsynchronouslyWrite 都是默认的 false），系统在主线程上调它们。下面几个 nonisolated(unsafe) 的属性都只在主线程上读写。
@objc(WorkbookDocument)
final class WorkbookDocument: NSDocument {
    nonisolated(unsafe) var loaded: LoadedWorkbook?
    /// 窗口建好以后的编辑状态。保存时从这里拿工作簿。
    nonisolated(unsafe) var session: SheetSession?
    /// 原包：保存时没改过的部件照抄（设计 7.2 节）。打开的是 csv 时没有。换了原包（存过、重新载入）就重新判断哪些表能插删行列。
    nonisolated(unsafe) var source: XLSXSource? {
        didSet { structureLocks = [:] }
    }
    /// 每张表能不能插删行列（StructureLock，设计第 11 条）：要解压、扫一遍包，按 sheet 编号记下来。
    nonisolated(unsafe) private var structureLocks: [Int: StructureLock?] = [:]
    /// 打开（或上次保存）时的工作簿：判断哪张 sheet 改过。
    nonisolated(unsafe) var baseline: Workbook?
    /// 打开的是 csv 时原来的写法（编码、分隔符、换行）。
    nonisolated(unsafe) var csvFormat: CSVFormat?
    /// 刚写好、核对过、还没确认存成功的：存成功以后它们成为新的原包和基准。
    nonisolated(unsafe) var pendingSave: (workbook: Workbook, source: XLSXSource?, csvFormat: CSVFormat?, bytes: Data)?
    /// 这次打开以后备份过原文件没有（第四道保险：第一次覆盖前备份）。
    var backedUp = false
    /// 恢复副本的编号（第五道保险）。从恢复副本打开的文档接着用那一份的编号：新副本写好之前旧的不删（RecoveryCoordinator.reopen）。
    var recoveryID = UUID()
    /// 恢复副本写好了的那一版（改动次数），和正在后台写的那一版。写成了才记进 recoveredRevision，没写成的下一轮重写。
    var recoveredRevision: Int?
    var recoveringRevision: Int?
    var autosaveWriter: WorkbookAutosave?
    var latestEdit: UUID?
    var lastSaveIssue: (any Error)?
    nonisolated static let aiConfirmationKey = "ConfirmAIWorkbookWrites"
    var savePreferences: UserDefaults = .standard
    var beforeUnconfirmedAI: Workbook?
    /// 从恢复副本打开的：原来那个文件。存的时候默认存回它旁边。
    var recoveredFrom: URL?

    override class var autosavesInPlace: Bool { false }

    override func read(from url: URL, ofType typeName: String) throws {
        let loaded = try DocumentLoader.load(contentsOf: url, typeName: typeName, history: WorkbookHistory(file: url))
        self.loaded = loaded
        source = loaded.source
        baseline = loaded.workbook
        csvFormat = loaded.csvFormat
    }

    override func makeWindowControllers() {
        guard let loaded else { return }
        let session = SheetSession(workbook: loaded.workbook, recalcCache: loaded.recalcCache)
        session.undoManager = undoManager
        session.structureLock = { [weak self] id in self?.structureLock(forSheet: id) }
        session.refusedChange = { [weak self] locked in LayoutCommands.explain(locked, in: self?.windowForSheet) }
        self.session = session
        if let fileURL { attachAutosave(url: fileURL, loaded: loaded) }
        session.didEdit = { [weak self] title, author, before in
            guard let self else { return }
            let needsConfirmation = savePreferences.bool(forKey: Self.aiConfirmationKey)
            if !needsConfirmation { beforeUnconfirmedAI = nil }
            if case .ai = author {
                if needsConfirmation, beforeUnconfirmedAI == nil { beforeUnconfirmedAI = before }
                saveStep(title, aiRound: AISession.shared.roundID)
            } else {
                if let beforeUnconfirmedAI, self.session?.workbook == beforeUnconfirmedAI { self.beforeUnconfirmedAI = nil }
                saveStep(title)
            }
        }
        addWindowController(WorkbookWindowController(session: session))
    }

    /// 「复原到上次存的样子」和「文件被别的程序改了，重新载入」：读回来以后换掉窗口里的工作簿，撤销记录清空。
    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        finishAutosave()
        try super.revert(toContentsOf: url, ofType: typeName)
        guard let loaded, let session else { return }
        session.editing = nil
        session.replaceWorkbook(loaded.workbook)
        session.resetSelection()
        attachAutosave(url: url, loaded: loaded)
        undoManager?.removeAllActions()
        backedUp = false
    }

    /// 这张表（按编号）为什么不能插删行列；能就是 nil。这次新建、复制、导入的表不在原包里，总是能。
    func structureLock(forSheet id: Int) -> StructureLock? {
        if let known = structureLocks[id] { return known }
        var lock = source?.structureLock(forSheet: id)
        // 复制出来的表不在原包里，模拟运算表却跟着复制过来了（Sheet.storedFormulas）：一样不能插删（PR #17 第一轮审查第 5 条）。
        if lock == nil, session?.workbook.sheets.first(where: { $0.id == id })?.dataTableCell != nil {
            lock = .otherContent("data table")
        }
        structureLocks[id] = lock
        return lock
    }

    // 必须在 NSDocument 判断是否有未保存修改之前提交；只在 save 或 close 里做会错过保存确认。
    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?,
                           contextInfo: UnsafeMutableRawPointer?) {
        // 实际修改才显式分组，让 NSDocument 同步脏状态；空组也会标脏，不能包住无变化的提交。
        session?.commitEditing(groupUndo: true)
        finishAutosave()
        super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
    }

    override func close() {
        session?.commitEditing()
        finishAutosave()
        RecoveryCoordinator.shared.forget(self)
        super.close()
    }
}

/// 给共用读入结果补上 Mac 实际字体量出的 CSV 列宽。文档窗口和截图模式走同一入口。
enum DocumentLoader {
    static func load(contentsOf url: URL, typeName: String? = nil, history: WorkbookHistory? = nil) throws -> LoadedWorkbook {
        var loaded = try LoadedWorkbook(data: Data(contentsOf: url), url: url, typeName: typeName, history: history)
        if loaded.csvFormat != nil, loaded.source == nil {
            // NSDocument 同步读文件、截图和测速都在主线程。只在量 Mac 字体时要求这个前提。
            loaded = MainActor.assumeIsolated { [loaded] in
                var fitted = loaded
                for index in fitted.workbook.sheets.indices {
                    fitted.workbook.sheets[index].columns = fittedColumns(for: loaded.workbook.sheets[index], in: loaded.workbook)
                }
                return fitted
            }
        }
        return loaded
    }

    /// 一张 sheet 按内容定的列宽（AI 从 csv 导进来的 sheet 也用它）。
    @MainActor
    static func fittedColumns(for sheet: Sheet, in workbook: Workbook) -> [ColumnFormat] {
        let styles = StyleResolver(workbook: workbook)
        let fonts = FontBook()
        return AutoFit.columns(for: sheet, styles: styles, dateSystem: workbook.dateSystem,
                               digitWidth: fonts.digitWidth(styles.style(0).font), measure: { fonts.width(of: $0, style: $1) })
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
