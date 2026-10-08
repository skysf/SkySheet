import Foundation

/// 第五道保险（设计第十节）：没保存的改动隔一会儿存一份恢复副本（xlsx，不碰原文件）。文档正常关掉（存了，或者
/// 用户选了不存）时删掉它；App 异常退出，下次启动时还在的就是要恢复的。
///
/// 没用 NSDocument 自带的「另处自动保存」：它恢复时要靠系统的窗口恢复，什么时候恢复、恢复成什么样不好控制，
/// 也没法在自检里测。自己写，规则简单、看得见（2026-10-08 M3 定的，设计第十节第 5 条）。
public struct RecoveryStore: Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let id: UUID
        /// 原文件（新建的、从 csv 来还没存成 xlsx 的也记原来那个 csv）。
        public let originalPath: String?
        public let displayName: String
        public let savedAt: Date

        public init(id: UUID, originalPath: String?, displayName: String, savedAt: Date) {
            self.id = id
            self.originalPath = originalPath
            self.displayName = displayName
            self.savedAt = savedAt
        }
    }

    public let root: URL

    public init(root: URL = SafetyFolders.recovery) {
        self.root = root
    }

    /// 存（或者更新）一份。先写数据再写说明，两个都是原子写：说明在，数据一定是完整的。
    public func save(_ data: Data, entry: Entry) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: dataURL(entry.id), options: .atomic)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entry).write(to: infoURL(entry.id), options: .atomic)
    }

    public func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: infoURL(id))
        try? FileManager.default.removeItem(at: dataURL(id))
    }

    /// 还在的恢复副本，新的在前。说明坏了或者数据丢了的跳过。
    public func entries() -> [Entry] {
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return items.filter { $0.pathExtension == "json" }
            .compactMap { url in (try? Data(contentsOf: url)).flatMap { try? decoder.decode(Entry.self, from: $0) } }
            .filter { FileManager.default.fileExists(atPath: dataURL($0.id).path) }
            .sorted { $0.savedAt > $1.savedAt }
    }

    public func dataURL(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString + ".xlsx")
    }

    private func infoURL(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString + ".json")
    }
}
