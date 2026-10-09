import Foundation

/// AI 的 sheet 的署名（设计第 23 条、9.3 节第 5 条）：谁建的、什么时候；最后是谁改的、什么时候。
/// 存进文件（docProps/custom.xml），下次打开还在；不写进 sheet 名。
public struct AIAuthorship: Hashable, Sendable {
    /// 一次署名：是谁（AI 的客户端和它自报的模型名，或者用户自己）、什么时候。
    public struct Mark: Hashable, Sendable {
        public enum Author: Hashable, Sendable {
            /// 客户端名来自 MCP 握手，是可靠的（如 "Claude Code"）；模型名是 AI 在 add_sheet 里自报的，可能为空。
            case ai(client: String, model: String?)
            case user
        }

        public var author: Author
        public var date: Date

        public init(_ author: Author, date: Date) {
            self.author = author
            self.date = date
        }
    }

    public var created: Mark
    public var lastChanged: Mark?

    public init(created: Mark, lastChanged: Mark? = nil) {
        self.created = created
        self.lastChanged = lastChanged
    }

    /// 页签小标上的名字：模型名认得出就用模型的品牌（claude-* → Claude），认不出用客户端名；用户自己标的写 "You"。
    /// 以后接别的 AI（第 17 条）靠的就是模型名这一项。
    public var badge: String {
        switch created.author {
        case .user:
            return "You"
        case .ai(let client, let model):
            return model.flatMap(Self.brand(ofModel:)) ?? Self.brand(ofClient: client)
        }
    }

    /// 模型名 → 品牌。认不出返回 nil。
    public static func brand(ofModel model: String) -> String? {
        let lowered = model.lowercased()
        let brands: [(prefixes: [String], name: String)] = [
            (["claude"], "Claude"), (["gpt", "o1", "o3", "o4", "chatgpt"], "ChatGPT"), (["deepseek"], "DeepSeek"),
            (["gemini"], "Gemini"), (["qwen"], "Qwen"), (["kimi", "moonshot"], "Kimi"), (["glm"], "GLM"),
            (["doubao"], "Doubao"), (["llama"], "Llama"), (["mistral"], "Mistral"), (["grok"], "Grok"),
        ]
        return brands.first { $0.prefixes.contains(where: lowered.hasPrefix) }?.name
    }

    /// 客户端报的名字多半是内部代号，换成人认得的（照搬 SrtFlow 的 AISession.displayName）。
    public static func brand(ofClient client: String) -> String {
        let lowered = client.lowercased()
        if lowered.contains("claude-code") || lowered.contains("claude code") { return "Claude Code" }
        if lowered.contains("claude") { return "Claude" }
        if lowered.contains("codex") { return "Codex" }
        if lowered.contains("cursor") { return "Cursor" }
        if lowered.contains("chatgpt") || lowered.contains("openai") { return "ChatGPT" }
        return client.isEmpty ? "AI" : client
    }
}
