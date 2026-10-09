import Foundation

// MARK: - Claude Code 的配置文件里关于 skysheet 的那几处（纯值，自检测得着；设计 9.5 节，从 SrtFlow 的 AIClientConfigFiles 搬来）
//
// - `~/.claude.json` 的 `mcpServers.skysheet.command`：连的是哪一份 skysheet-mcp。**只读**：正在跑的 Claude Code 会整份
//   重写它，直接改会被冲掉，所以连接走它自己的命令行 `claude mcp add`。
// - `~/.claude/settings.json` 的 `permissions.allow` 里加 `mcp__skysheet`：放行 SkySheet 的全部工具，不用每个都点一次
//   「允许」。只动这一条，别的原样留着；文件格式不对就报错、一个字节都不写。

public enum ClaudeCodeConfig {
    public static let serverName = MCPServerCore.serverName
    /// Claude Code 里 `mcp__<服务器名>` 匹配这个服务器的每一个工具。
    public static let allowRule = "mcp__\(serverName)"

    public struct FormatError: Error, Equatable {
        public let message: String
    }

    /// ~/.claude.json 里 skysheet 连的小程序路径；没连返回 nil。
    public static func command(in data: Data?) -> String? {
        guard let data, !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any],
              let entry = servers[serverName] as? [String: Any] else { return nil }
        return entry["command"] as? String
    }

    public static func allows(in data: Data?) -> Bool {
        guard let data, !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let allow = (root["permissions"] as? [String: Any])?["allow"] as? [String] else { return false }
        return allow.contains(allowRule)
    }

    /// 加上放行规则（已经有就不重复）。
    public static func allowing(in data: Data?) throws(FormatError) -> Data {
        try editingAllowList(data) { allow in
            if !allow.contains(allowRule) { allow.append(allowRule) }
        }
    }

    public static func disallowing(in data: Data?) throws(FormatError) -> Data {
        try editingAllowList(data) { allow in allow.removeAll { $0 == allowRule } }
    }

    private static func editingAllowList(_ data: Data?, _ edit: (inout [String]) -> Void) throws(FormatError) -> Data {
        var root = try jsonRoot(data)
        guard var permissions = (root["permissions"] ?? [String: Any]()) as? [String: Any] else {
            throw FormatError(message: "\"permissions\" in the settings file is not an object, so SkySheet left it alone.")
        }
        guard var allow = (permissions["allow"] ?? [String]()) as? [String] else {
            throw FormatError(message: "\"permissions.allow\" in the settings file is not a list, so SkySheet left it alone.")
        }
        edit(&allow)
        permissions["allow"] = allow
        root["permissions"] = permissions
        do {
            return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw FormatError(message: "SkySheet could not write the settings file.")
        }
    }

    private static func jsonRoot(_ data: Data?) throws(FormatError) -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FormatError(message: "The settings file is not valid JSON, so SkySheet left it alone.")
        }
        return root
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
