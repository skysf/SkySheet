import AppKit
import Observation
import SkySheetMCPKit

/// 「连接 Claude Code」（设计 9.5 节，照 SrtFlow 的 AIClientSetup 只留 Claude Code 一家，第 17 条）：
/// 跑 `claude mcp add --scope user skysheet -- <包里的 skysheet-mcp>`，再往 ~/.claude/settings.json 的 permissions.allow 里加
/// `mcp__skysheet`（按原文只插这一条，第一次改之前备份；`ClaudeCodeConfig.updateSettings`）。找不到 claude 命令行就给「复制一段话」。
/// 状态有四种：没装 Claude Code / 没连接 / 已连接（每次都会问的算没放行）/ 连着另一份 SkySheet（App 挪过位置）。
@MainActor
@Observable
final class ClaudeCodeSetup {
    static let shared = ClaudeCodeSetup()

    enum Status: Equatable {
        case notInstalled
        case notConnected
        case connected
        /// 连着这一份，但工具还没放行：每个工具都会问一次。再点「连接」补上。
        case connectedAsking
        /// 连着的是另一份 SkySheet（App 挪过位置，或者装过测试版）。
        case connectedElsewhere
    }

    private(set) var status: Status = .notInstalled
    private(set) var busy = false
    var message: String?

    private let home = MCPBridge.realHomeDirectory()
    private var configPath: String { home + "/.claude.json" }
    private var settingsPath: String { home + "/.claude/settings.json" }

    private init() {}

    /// 包里的那个小程序。`swift run` 直接跑的开发版里没有它。
    var helperURL: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/skysheet-mcp")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Claude Code 的命令行装在哪（官方安装器、npm、Homebrew 几个常见位置）。
    var cli: URL? {
        [home + "/.local/bin/claude", home + "/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
         home + "/.npm-global/bin/claude", home + "/.bun/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    func refresh() {
        guard FileManager.default.fileExists(atPath: configPath) || cli != nil else {
            status = .notInstalled
            return
        }
        guard let command = ClaudeCodeConfig.command(in: FileManager.default.contents(atPath: configPath)) else {
            status = .notConnected
            return
        }
        guard command == helperURL?.path else {
            status = .connectedElsewhere
            return
        }
        status = ClaudeCodeConfig.allows(in: FileManager.default.contents(atPath: settingsPath)) ? .connected : .connectedAsking
    }

    func connect() async {
        guard let helper = helperURL, let cli else { return }
        busy = true
        defer {
            busy = false
            refresh()
        }
        // 已经有一条的话 add 会失败：先删再加（删不掉 = 本来就没有，不算错）。
        _ = await ChildProcess.exitStatus(cli, ["mcp", "remove", "--scope", "user", ClaudeCodeConfig.serverName])
        let status = await ChildProcess.exitStatus(cli, ["mcp", "add", "--scope", "user", ClaudeCodeConfig.serverName,
                                                         "--", helper.path])
        guard status == 0 else {
            message = String(localized: "Could not connect: claude mcp add exited with \(status).")
            return
        }
        do {
            try ClaudeCodeConfig.updateSettings(at: settingsPath, ClaudeCodeConfig.allowing(in:))
            message = String(localized: """
                Connected. Start a new Claude Code session so it picks up SkySheet; it will use SkySheet's tools without asking.
                """)
        } catch let error as ClaudeCodeConfig.FormatError {
            message = String(localized: "Connected, but SkySheet could not update Claude Code's settings: \(error.message)")
        } catch {
            message = String(localized: "Connected, but SkySheet could not update Claude Code's settings: \(error.localizedDescription)")
        }
    }

    func disconnect() async {
        guard let cli else { return }
        busy = true
        defer {
            busy = false
            refresh()
        }
        _ = await ChildProcess.exitStatus(cli, ["mcp", "remove", "--scope", "user", ClaudeCodeConfig.serverName])
        try? ClaudeCodeConfig.updateSettings(at: settingsPath, ClaudeCodeConfig.disallowing(in:))
        message = String(localized: "Disconnected. Restart Claude Code to finish.")
    }

    func copyPrompt() {
        guard let helper = helperURL?.path else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ClaudeCodeConfig.setupPrompt(helper: helper), forType: .string)
        message = String(localized: "Copied. Paste it into Claude Code.")
    }
}

/// 跑一个外部命令、等它结束，只拿退出码（照 SrtFlow 的 ChildProcess）。用结束回调接 continuation，不占着线程等。
enum ChildProcess {
    static func exitStatus(_ executable: URL, _ arguments: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: -1)
            }
        }
    }
}
