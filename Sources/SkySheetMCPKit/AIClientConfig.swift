import Foundation

// MARK: - AI 客户端的配置文件：两家共用的那部分（设计 9.5 节）
//
// 管什么：读 `mcpServers.skysheet.command`（连的是哪一份 skysheet-mcp；Claude Code 的 ~/.claude.json 和 Claude 桌面版的
// claude_desktop_config.json 都这么写）；改文件的规矩：先让 JSONSerialization 验合法，不合法（带注释的也算）一个字节都不写；
// 第一次改之前在旁边备份；软链接写进它指向的文件；原子写回；没有要改的就不写。
// 不管什么：每家改哪一处、怎么改（ClaudeCodeConfig、ClaudeDesktopConfig，都按原文只动那一处：JSONText）。

public enum AIClientConfig {
    public static let serverName = MCPServerCore.serverName

    public struct FormatError: Error, Equatable {
        public let message: String
    }

    /// 配置里 skysheet 连的小程序路径；没连返回 nil。
    public static func command(in data: Data?) -> String? {
        guard let data, !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any],
              let entry = servers[serverName] as? [String: Any] else { return nil }
        return entry["command"] as? String
    }

    /// 扫好的原文；没有文件、空文件返回 nil。不合法的、根不是对象的报 `invalid`：一个字节都不碰。
    static func scan(_ data: Data?, invalid: FormatError) throws(FormatError) -> JSONText? {
        guard let data, !data.allSatisfy(JSONText.isWhitespace) else { return nil }
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any], let text = JSONText(data) else {
            throw invalid
        }
        return text
    }

    /// 改配置文件：读 → 改 → 原子写回；`transform` 返回 nil（没有要改的）就一个字节都不写。
    /// 第一次改之前在旁边备份一份原文件（`.skysheet-backup`），改坏了能找回来。备份用复制、权限跟着原文件：
    /// Claude 桌面版的配置只许自己读（0600），写一份新文件会变成谁都能读。
    /// 它是软链接（dotfiles 常这么放）就写进它指向的文件：原子写是「写临时文件再改名」，直接写会把链接换成普通文件。
    public static func update(at path: String, _ transform: (Data?) throws(FormatError) -> Data?) throws {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let original = FileManager.default.contents(atPath: target.path)
        guard let next = try transform(original) else { return }
        let backup = path + ".skysheet-backup"
        if original != nil, !FileManager.default.fileExists(atPath: backup) {
            try FileManager.default.copyItem(atPath: target.path, toPath: backup)
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try next.write(to: target, options: .atomic)
    }
}
