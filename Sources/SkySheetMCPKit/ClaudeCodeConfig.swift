import Foundation

// MARK: - Claude Code 的配置文件里关于 skysheet 的那几处（纯值，自检测得着；设计 9.5 节，从 SrtFlow 的 AIClientConfigFiles 搬来）
//
// - `~/.claude.json` 的 `mcpServers.skysheet.command`：连的是哪一份 skysheet-mcp。**只读**：正在跑的 Claude Code 会整份
//   重写它，直接改会被冲掉，所以连接走它自己的命令行 `claude mcp add`。
// - `~/.claude/settings.json` 的 `permissions.allow` 里加 `mcp__skysheet`：放行 SkySheet 的全部工具，不用每个都点一次
//   「允许」。只动这一条，别的原样留着：**按原文插进或删掉这一条（JSONText），不整份解析再写回**（v0.3.0 整份重写过，
//   键被排序、空格全变）。文件格式不对就报错、一个字节都不写。

public enum ClaudeCodeConfig {
    public static let serverName = MCPServerCore.serverName
    /// Claude Code 里 `mcp__<服务器名>` 匹配这个服务器的每一个工具。
    public static let allowRule = "mcp__\(serverName)"

    public struct FormatError: Error, Equatable {
        public let message: String
    }

    private static let notJSON = FormatError(message: "The settings file is not valid JSON, so SkySheet left it alone.")
    private static let permissionsNotObject = FormatError(
        message: "\"permissions\" in the settings file is not an object, so SkySheet left it alone.")
    private static let allowNotList = FormatError(
        message: "\"permissions.allow\" in the settings file is not a list, so SkySheet left it alone.")

    /// ~/.claude.json 里 skysheet 连的小程序路径；没连返回 nil。
    public static func command(in data: Data?) -> String? {
        guard let data, !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any],
              let entry = servers[serverName] as? [String: Any] else { return nil }
        return entry["command"] as? String
    }

    public static func allows(in data: Data?) -> Bool {
        guard let text = try? settings(data),
              let rules = text.root.member("permissions")?.value.member("allow")?.value.elements else { return false }
        return rules.contains { $0.string == allowRule }
    }

    /// 加上放行规则：在原文的 allow 列表末尾插进这一条（没有列表就补上），别的字节原样留着。
    /// 已经有了返回 nil：不用写。
    public static func allowing(in data: Data?) throws(FormatError) -> Data? {
        let rule = JSONNewValue.string(allowRule)
        guard let text = try settings(data) else {
            let fresh = JSONNewValue.object([("permissions", .object([("allow", .array([rule]))]))])
            return Data((JSONLayout().render(fresh, indent: "") + "\n").utf8)
        }
        guard let permissions = text.root.member("permissions") else {
            return text.addingMember("permissions", .object([("allow", .array([rule]))]), to: text.root, in: nil)
        }
        guard permissions.value.members != nil else { throw permissionsNotObject }
        guard let allow = permissions.value.member("allow") else {
            return text.addingMember("allow", .array([rule]), to: permissions.value, in: permissions)
        }
        guard let rules = allow.value.elements else { throw allowNotList }
        if rules.contains(where: { $0.string == allowRule }) { return nil }
        guard rules.allSatisfy({ $0.string != nil }) else { throw allowNotList }
        return text.addingElement(rule, to: allow.value, in: allow)
    }

    /// 去掉放行规则（出现几次去几次），只删它和它的逗号。没有返回 nil：不用写。
    public static func disallowing(in data: Data?) throws(FormatError) -> Data? {
        guard var text = try settings(data) else { return nil }
        var changed = false
        while let permissions = text.root.member("permissions") {
            guard permissions.value.members != nil else { throw permissionsNotObject }
            guard let allow = permissions.value.member("allow") else { break }
            guard let rules = allow.value.elements else { throw allowNotList }
            guard let index = rules.firstIndex(where: { $0.string == allowRule }) else { break }
            guard let next = JSONText(text.removingElement(at: index, of: allow.value)) else {
                throw FormatError(message: "SkySheet could not write the settings file.")
            }
            text = next
            changed = true
        }
        return changed ? Data(text.bytes) : nil
    }

    /// 扫好的 settings.json；没有文件、空文件返回 nil。先让 JSONSerialization 验一遍：不合法的（带注释的也算）一律不碰。
    private static func settings(_ data: Data?) throws(FormatError) -> JSONText? {
        guard let data, !data.allSatisfy(JSONText.isWhitespace) else { return nil }
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any], let text = JSONText(data) else {
            throw notJSON
        }
        return text
    }

    /// 改 settings.json：读 → 改 → 原子写回；`transform` 返回 nil（没有要改的）就一个字节都不写。
    /// 第一次改之前在旁边备份一份原文件（`.skysheet-backup`），改坏了能找回来。
    /// 它是软链接（dotfiles 常这么放）就写进它指向的文件：原子写是「写临时文件再改名」，直接写会把链接换成普通文件。
    public static func updateSettings(at path: String, _ transform: (Data?) throws(FormatError) -> Data?) throws {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let original = FileManager.default.contents(atPath: target.path)
        guard let next = try transform(original) else { return }
        let backup = path + ".skysheet-backup"
        if let original, !FileManager.default.fileExists(atPath: backup) {
            try original.write(to: URL(fileURLWithPath: backup))
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try next.write(to: target, options: .atomic)
    }

    /// 找不到 claude 命令行时，「复制一段话」贴给 Claude Code，让它自己装。
    public static func setupPrompt(helper: String) -> String {
        """
        Please connect the SkySheet spreadsheet app to Claude Code: run this command in the terminal, add \
        "\(allowRule)" to permissions.allow in ~/.claude/settings.json so its tools run without asking, then tell me \
        to start a new session.

        claude mcp add --scope user \(serverName) -- "\(helper)"
        """
    }
}
