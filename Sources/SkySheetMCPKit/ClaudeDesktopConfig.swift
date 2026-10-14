import Foundation

// MARK: - Claude 桌面版的配置里关于 skysheet 的那一项（纯值，自检测得着；设计 9.5 节、第 17 条）
//
// `~/Library/Application Support/Claude/claude_desktop_config.json` 的 `mcpServers.skysheet`：桌面版的普通聊天启动哪一份
// skysheet-mcp（它的 Code 页跑的是 Claude Code，用 Claude Code 自己的配置）。官方就是让用户改这个文件，没有命令行。
// 只动这一项，按原文插进、换掉或删掉（JSONText），别的原样留着；文件格式不对就报错、一个字节都不写。
//
// **它开着的时候，改了会被它盖掉**：桌面版启动时把整个文件读进内存，之后每次存自己的偏好（开 Code 会话、切窗格……
// 一天十几次）都把内存里那份整份写回，不先重读；退出时不写；mcpServers 也只在启动时读（2026-10-09 读 Claude
// 2.31226.0 的代码和日志确认）。所以它开着时改的，要在它退出那一刻再写一遍（App 那一头：ClaudeDesktopSetup）。

public enum ClaudeDesktopConfig {
    public static let bundleIdentifier = "com.anthropic.claudefordesktop"

    public static func path(home: String) -> String {
        home + "/Library/Application Support/Claude/claude_desktop_config.json"
    }

    private static let notJSON = AIClientConfig.FormatError(
        message: "Claude's config file is not valid JSON, so SkySheet left it alone.")
    private static let serversNotObject = AIClientConfig.FormatError(
        message: "\"mcpServers\" in Claude's config file is not an object, so SkySheet left it alone.")

    /// 让 skysheet 这一项启动 `helper`。没有就加在 mcpServers 末尾（没有 mcpServers 就补上）；指着别的小程序（App 挪过
    /// 位置）就只换掉 command 那个字符串，这一项里别的（env 之类）留着。已经是它返回 nil：不用写。
    public static func connecting(helper: String, in data: Data?) throws(AIClientConfig.FormatError) -> Data? {
        let name = AIClientConfig.serverName
        let entry = JSONNewValue.object([("command", .string(helper)), ("args", .array([]))])
        guard let text = try AIClientConfig.scan(data, invalid: notJSON) else {
            // 没有文件：照桌面版自己写的样子（两格缩进，末尾不换行）。
            return Data(JSONLayout().render(.object([("mcpServers", .object([(name, entry)]))]), indent: "").utf8)
        }
        guard let servers = text.root.member("mcpServers") else {
            return text.addingMember("mcpServers", .object([(name, entry)]), to: text.root, in: nil)
        }
        guard servers.value.members != nil else { throw serversNotObject }
        guard let current = servers.value.member(name) else {
            return text.addingMember(name, entry, to: servers.value, in: servers)
        }
        guard let command = current.value.member("command"), let path = command.value.string else {
            return text.replacingValue(current.value, with: entry, in: current)
        }
        return path == helper ? nil : text.replacingValue(command.value, with: .string(helper), in: command)
    }

    /// 去掉 skysheet 这一项（写了几次去几次），只删它和它的逗号；mcpServers 空了留着 `{}`。没有返回 nil：不用写。
    public static func disconnecting(in data: Data?) throws(AIClientConfig.FormatError) -> Data? {
        guard var text = try AIClientConfig.scan(data, invalid: notJSON) else { return nil }
        var changed = false
        while let servers = text.root.member("mcpServers") {
            guard let members = servers.value.members else { throw serversNotObject }
            guard let index = members.lastIndex(where: { $0.key == AIClientConfig.serverName }) else { break }
            guard let next = JSONText(text.removingMember(at: index, of: servers.value)) else {
                throw AIClientConfig.FormatError(message: "SkySheet could not write Claude's config file.")
            }
            text = next
            changed = true
        }
        return changed ? Data(text.bytes) : nil
    }
}
