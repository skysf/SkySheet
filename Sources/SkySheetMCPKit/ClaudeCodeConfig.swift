import Foundation

// MARK: - Claude Code 的配置文件里关于 skysheet 的那几处（纯值，自检测得着；设计 9.5 节，从 SrtFlow 的 AIClientConfigFiles 搬来）
//
// - `~/.claude.json` 的 `mcpServers.skysheet.command`（`AIClientConfig.command`）：连的是哪一份 skysheet-mcp。**只读**：
//   正在跑的 Claude Code 会整份重写它，直接改会被冲掉，所以连接走它自己的命令行 `claude mcp add`。
// - `~/.claude/settings.json` 的 `permissions.allow` 里加 `mcp__skysheet`：放行 SkySheet 的全部工具，不用每个都点一次
//   「允许」。只动这一条，别的原样留着：**按原文插进或删掉这一条（JSONText），不整份解析再写回**（v0.3.0 整份重写过，
//   键被排序、空格全变）。文件格式不对就报错、一个字节都不写。改文件走 `AIClientConfig.update`。

public enum ClaudeCodeConfig {
    /// Claude Code 里 `mcp__<服务器名>` 匹配这个服务器的每一个工具。
    public static let allowRule = "mcp__\(AIClientConfig.serverName)"

    private static let notJSON = AIClientConfig.FormatError(
        message: "The settings file is not valid JSON, so SkySheet left it alone.")
    private static let permissionsNotObject = AIClientConfig.FormatError(
        message: "\"permissions\" in the settings file is not an object, so SkySheet left it alone.")
    private static let allowNotList = AIClientConfig.FormatError(
        message: "\"permissions.allow\" in the settings file is not a list, so SkySheet left it alone.")

    public static func allows(in data: Data?) -> Bool {
        guard let text = try? AIClientConfig.scan(data, invalid: notJSON),
              let rules = text.root.member("permissions")?.value.member("allow")?.value.elements else { return false }
        return rules.contains { $0.string == allowRule }
    }

    /// 加上放行规则：在原文的 allow 列表末尾插进这一条（没有列表就补上），别的字节原样留着。
    /// 已经有了返回 nil：不用写。
    public static func allowing(in data: Data?) throws(AIClientConfig.FormatError) -> Data? {
        let rule = JSONNewValue.string(allowRule)
        guard let text = try AIClientConfig.scan(data, invalid: notJSON) else {
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
    public static func disallowing(in data: Data?) throws(AIClientConfig.FormatError) -> Data? {
        guard var text = try AIClientConfig.scan(data, invalid: notJSON) else { return nil }
        var changed = false
        while let permissions = text.root.member("permissions") {
            guard permissions.value.members != nil else { throw permissionsNotObject }
            guard let allow = permissions.value.member("allow") else { break }
            guard let rules = allow.value.elements else { throw allowNotList }
            guard let index = rules.firstIndex(where: { $0.string == allowRule }) else { break }
            guard let next = JSONText(text.removingElement(at: index, of: allow.value)) else {
                throw AIClientConfig.FormatError(message: "SkySheet could not write the settings file.")
            }
            text = next
            changed = true
        }
        return changed ? Data(text.bytes) : nil
    }

    /// 找不到 claude 命令行时，「复制一段话」贴给 Claude Code，让它自己装。
    public static func setupPrompt(helper: String) -> String {
        """
        Please connect the SkySheet spreadsheet app to Claude Code: run this command in the terminal, add \
        "\(allowRule)" to permissions.allow in ~/.claude/settings.json so its tools run without asking, then tell me \
        to start a new session.

        claude mcp add --scope user \(AIClientConfig.serverName) -- "\(helper)"
        """
    }
}
