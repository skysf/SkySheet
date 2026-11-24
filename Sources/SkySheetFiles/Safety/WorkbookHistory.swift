import CryptoKit
import Foundation
import SkyZip

/// 每次提交一个条目。工作簿中没改过的 ZIP 部件共用磁盘内容，历史放在应用自己的目录里。
public struct WorkbookHistory: Sendable {
    public struct Version: Codable, Identifiable, Sendable {
        public let id: UUID
        public let date: Date
        public let title: String
        fileprivate let fileName: String
        fileprivate let digest: String
        fileprivate let parts: [String]
        fileprivate let diskDigest: String?
    }

    private let folder: URL
    private var parts: URL { folder.appendingPathComponent("Parts", isDirectory: true) }

    public init(file: URL, root: URL = SafetyFolders.applicationSupport.appendingPathComponent("History")) {
        let path = file.standardizedFileURL.resolvingSymlinksInPath().path
        // iOS 更新应用时沙盒的绝对路径可能变，应用自己的文稿按相对路径认。
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path + "/"
        let key = path.hasPrefix(home) ? "~/" + String(path.dropFirst(home.count)) : path
        folder = root.appendingPathComponent(Self.digest(Data(key.utf8)), isDirectory: true)
    }

    public func versions() throws -> [Version] {
        try manifests().map { try JSONDecoder().decode(Version.self, from: Data(contentsOf: $0)) }
    }

    /// CSV 本身保存第一张表的值。在同一台设备上，文件仍是当时那份时，还原历史里的公式、样式和其余工作表。
    func latestWorkbook(matching bytes: Data) throws -> LoadedWorkbook? {
        guard let url = try manifests().first else { return nil }
        let entry = try JSONDecoder().decode(Version.self, from: Data(contentsOf: url))
        guard entry.fileName == "Version.xlsx", entry.diskDigest == Self.digest(bytes) else { return nil }
        return try load(entry)
    }

    public func load(_ version: Version) throws -> LoadedWorkbook {
        var data = Data()
        for hash in version.parts {
            let bytes = try Data(contentsOf: parts.appendingPathComponent(hash))
            guard Self.digest(bytes) == hash else { throw CocoaError(.fileReadCorruptFile) }
            data.append(bytes)
        }
        guard Self.digest(data) == version.digest else { throw CocoaError(.fileReadCorruptFile) }
        return try LoadedWorkbook(data: data, url: URL(fileURLWithPath: version.fileName))
    }

    /// 第一次编辑时也记下打开时的版本。已打开的版本正好是上次落盘的那一步，就接着它写。
    /// 同一步重试沿用 UUID；多个窗口或进程写到同一份历史时，在目录级协调区里分配顺序。
    func record(id: UUID, title: String, xlsx: Data, diskBytes: Data?, opened: Data?, fileName: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: parts, withIntermediateDirectories: true)
        var coordination: NSError?
        var result: Result<Void, Error> = .failure(CocoaError(.fileWriteUnknown))
        NSFileCoordinator().coordinate(writingItemAt: folder, options: .forMerging, error: &coordination) { _ in
            result = Result {
                let existing = try manifests()
                if existing.contains(where: { $0.lastPathComponent.hasSuffix(id.uuidString + ".json") }) { return }
                var number = existing.first.flatMap { Int($0.lastPathComponent.prefix(16)) } ?? 0
                func append(_ id: UUID, _ title: String, _ bytes: Data, _ name: String, _ diskHash: String?) throws {
                    let ranges = name.lowercased().hasSuffix(".xlsx")
                        ? try ZipArchive(data: bytes).storageRanges : [0..<bytes.count]
                    let hashes = try ranges.map { range in
                        let part = bytes.subdata(in: range)
                        let hash = Self.digest(part)
                        let url = parts.appendingPathComponent(hash)
                        if !fm.fileExists(atPath: url.path) { try part.write(to: url, options: .atomic) }
                        return hash
                    }
                    let item = Version(id: id, date: Date(), title: title, fileName: name,
                                       digest: Self.digest(bytes), parts: hashes, diskDigest: diskHash)
                    number += 1
                    let name = String(format: "%016lld-", Int64(number)) + id.uuidString + ".json"
                    try JSONEncoder().encode(item).write(to: folder.appendingPathComponent(name), options: .atomic)
                }
                if let opened {
                    let hash = Self.digest(opened)
                    let previous = try existing.first.map { try JSONDecoder().decode(Version.self, from: Data(contentsOf: $0)) }
                    if previous?.diskDigest != hash {
                        try append(UUID(), String(localized: "Opened Version"), opened, fileName, hash)
                    }
                }
                try append(id, title, xlsx, "Version.xlsx", diskBytes.map(Self.digest))
            }
        }
        if let coordination { throw coordination }
        try result.get()
    }

    private func manifests() throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
