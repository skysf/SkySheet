import Foundation

/// 第四道保险（设计第十节）：一个文件在 SkySheet 里第一次被覆盖之前，先把原文件复制一份到
/// `~/Library/Application Support/ai.skylu.skysheet/Backups/<文件名> (<路径的短哈希>)/<时间>.<扩展名>`，
/// 每个文件留最近 10 份。不同文件夹里同名的文件靠短哈希分开。
public struct BackupStore: Sendable {
    public let root: URL
    public let keep: Int

    public init(root: URL = SafetyFolders.backups, keep: Int = 10) {
        self.root = root
        self.keep = keep
    }

    /// 复制一份，返回备份的位置。超过 `keep` 份就删掉最旧的。
    @discardableResult
    public func backUp(_ file: URL, now: Date = Date()) throws -> URL {
        let folder = self.folder(for: file)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stamp = formatter.string(from: now)
        let pathExtension = file.pathExtension.isEmpty ? "" : "." + file.pathExtension
        var target = folder.appendingPathComponent(stamp + pathExtension)
        var number = 2
        while FileManager.default.fileExists(atPath: target.path) {
            // "_2" 按字符排在 "." 后面：同一秒的第二份排在第一份前面（新的在前）。
            target = folder.appendingPathComponent("\(stamp)_\(number)\(pathExtension)")
            number += 1
        }
        try FileManager.default.copyItem(at: file, to: target)
        for old in backups(of: file).dropFirst(keep) {
            try? FileManager.default.removeItem(at: old)
        }
        return target
    }

    /// 这个文件的备份，新的在前（文件名就是时间，按字符排）。
    public func backups(of file: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder(for: file), includingPropertiesForKeys: nil)) ?? []
        return items.filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func folder(for file: URL) -> URL {
        root.appendingPathComponent("\(file.lastPathComponent) (\(SafetyFolders.shortHash(file.deletingLastPathComponent().path)))",
                                    isDirectory: true)
    }
}

/// 备份和恢复副本放在哪里。
public enum SafetyFolders {
    public static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("ai.skylu.skysheet", isDirectory: true)
    }

    public static var backups: URL { applicationSupport.appendingPathComponent("Backups", isDirectory: true) }
    public static var recovery: URL { applicationSupport.appendingPathComponent("Recovery", isDirectory: true) }

    /// 路径的 FNV-1a 哈希，8 位十六进制。只用来把同名文件分开，不用于安全。
    static func shortHash(_ text: String) -> String {
        var hash: UInt32 = 0x811C_9DC5
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return String(format: "%08x", hash)
    }
}
