import Foundation
import SkySheetCore

/// 一份已打开的文稿有一条串行队列。保留每次操作的值类型快照，上一份尚在写也不会合并掉中间步骤。
public final class WorkbookAutosave: @unchecked Sendable {
    public enum Issue: LocalizedError {
        case externalChange
        public var errorDescription: String? {
            String(localized: "Another app changed this file. Your edit is in Version History. Reopen the file or save a separate copy.")
        }
    }

    public struct Change: Sendable {
        public let id = UUID()
        public let title: String
        public let workbook: Workbook
        public let source: XLSXSource?
        public let baseline: Workbook?
        public init(_ title: String, workbook: Workbook, source: XLSXSource?, baseline: Workbook?) {
            self.title = title
            self.workbook = workbook
            self.source = source
            self.baseline = baseline
        }
    }

    public struct Receipt: Sendable {
        public let id: UUID
        public let modificationDate: Date?
        public let error: (any Error)?
    }

    public let history: WorkbookHistory
    public let url: URL
    private let queue = DispatchQueue(label: "ai.skylu.skyfolio.autosave", qos: .userInitiated)
    private weak var presenter: (any NSFilePresenter)?
    private let backups: BackupStore
    private let csvFormat: CSVFormat?
    private var expectedBytes: Data
    private var opened: Data?
    private var needsBackup = true
    private var pending: [Change] = []
    private var lastReceipt: Receipt?

    public init(url: URL, loaded: LoadedWorkbook, history: WorkbookHistory, backups: BackupStore = BackupStore(),
                presenter: (any NSFilePresenter)? = nil) {
        self.url = url
        self.history = history
        self.backups = backups
        self.presenter = presenter
        self.csvFormat = loaded.csvFormat
        expectedBytes = loaded.originalData
        opened = loaded.originalData
    }

    /// 输入、粘贴、撤销和恢复版本都走这里。历史写失败的步骤保留，下次提交时按原顺序重试。
    public func submit(_ change: Change, completion: @escaping @MainActor @Sendable (Receipt) -> Void) {
        queue.async { [self] in
            pending.append(change)
            let receipt = processPending()
            Task { @MainActor in completion(receipt) }
        }
    }

    /// 关闭、另存或重新加载前的屏障；后台工作不等主线程来确认。
    public func flush() -> Receipt? {
        queue.sync { pending.isEmpty ? lastReceipt : processPending() }
    }

    private func processPending() -> Receipt {
        var receipt: Receipt!
        while let change = pending.first {
            var recorded = false
            do {
                let workbook = change.workbook
                let result = try XLSXWriter.write(workbook, source: change.source, baseline: change.baseline)
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: temp) }
                try result.data.write(to: temp)
                let xlsx = try Data(contentsOf: temp)
                _ = try SaveVerifier.verify(xlsx, written: result, workbook: workbook, source: change.source)
                var bytes = xlsx
                if let csvFormat {
                    guard let sheet = workbook.sheets.first else { throw CocoaError(.fileWriteUnknown) }
                    let csv = try CSVWriter.write(sheet, styles: workbook.styles, dateSystem: workbook.dateSystem, format: csvFormat)
                    try csv.data.write(to: temp)
                    bytes = try Data(contentsOf: temp)
                    try CSVWriter.verify(bytes, written: csv)
                }
                try history.record(id: change.id, title: change.title, xlsx: xlsx, diskBytes: bytes,
                                   opened: opened, fileName: url.lastPathComponent)
                opened = nil
                recorded = true
                let date = try replace(with: bytes)
                receipt = Receipt(id: change.id, modificationDate: date, error: nil)
            } catch {
                receipt = Receipt(id: change.id, modificationDate: nil, error: error)
            }
            if recorded { pending.removeFirst() } else { break }
        }
        lastReceipt = receipt
        return receipt
    }

    private func replace(with bytes: Data) throws -> Date? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var error: NSError?
        var result: Result<Date?, Error> = .failure(CocoaError(.fileWriteUnknown))
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &error) { destination in
            result = Result {
                // 在同一次协调里比原字节、备份和原子替换，修改时间一样的外部写入也能发现。
                guard try Data(contentsOf: destination) == expectedBytes else { throw Issue.externalChange }
                if bytes != expectedBytes {
                    if needsBackup { try backups.backUp(destination) }
                    try bytes.write(to: destination, options: .atomic)
                    needsBackup = false
                    expectedBytes = bytes
                }
                return try? destination.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }
        }
        if let error { throw error }
        return try result.get()
    }
}
