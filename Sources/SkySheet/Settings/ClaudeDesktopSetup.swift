import AppKit
import Observation
import SkySheetMCPKit

/// 「连接 Claude 桌面版」（设计 9.5 节、第 17 条）：往 claude_desktop_config.json 的 mcpServers 里加 skysheet（按原文只动
/// 这一项，第一次改之前备份；`ClaudeDesktopConfig`、`AIClientConfig.update`），桌面版的普通聊天下次启动就能用 SkySheet。
/// 它的 Code 页跑的是 Claude Code，走 ClaudeCodeSetup 那一行。
///
/// 它开着的时候会拿内存里的那份把文件整份盖掉（见 ClaudeDesktopConfig）：所以点的时候它开着，就记下要的结果，在它退出
/// 那一刻再写一遍（那时没人盖了），提示用户退出再打开 Claude。SkySheet 先退出的话这一步就没人做了：提示里说了要开着；
/// 真被盖掉了，设置里显示没连上，再点一次就好。
/// 「总是允许」存在它自己那里，SkySheet 写不了：连上以后的提示里告诉用户在哪点。
@MainActor
@Observable
final class ClaudeDesktopSetup {
    static let shared = ClaudeDesktopSetup()

    private(set) var status: AIClientStatus = .notInstalled
    var message: String?
    /// 这次运行里点过、点的时候 Claude 开着、它还没退出过：true 要连上，false 要断开。它退出那一刻照这个再写一遍。
    private var pending: Bool?

    private let configPath = ClaudeDesktopConfig.path(home: MCPBridge.realHomeDirectory())

    private init() {
        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == ClaudeDesktopConfig.bundleIdentifier else { return }
            MainActor.assumeIsolated { ClaudeDesktopSetup.shared.claudeQuit() }
        }
    }

    private var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: ClaudeDesktopConfig.bundleIdentifier) != nil
            || FileManager.default.fileExists(atPath: (configPath as NSString).deletingLastPathComponent)
    }

    private var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: ClaudeDesktopConfig.bundleIdentifier).isEmpty
    }

    func refresh() {
        guard isInstalled else {
            status = .notInstalled
            return
        }
        if let pending {
            status = .restartNeeded(connecting: pending)
            return
        }
        guard let command = AIClientConfig.command(in: FileManager.default.contents(atPath: configPath)) else {
            status = .notConnected
            return
        }
        status = command == AIHelper.url?.path ? .connected : .connectedElsewhere
    }

    func connect() { change(connecting: true) }

    func disconnect() { change(connecting: false) }

    private func change(connecting: Bool) {
        defer { refresh() }
        guard write(connecting) else { return }
        guard isRunning else {
            pending = nil
            message = connecting ? Self.connected : String(localized: "Disconnected.")
            return
        }
        pending = connecting
        message = connecting
            ? String(localized: """
                Added to Claude's settings. Quit Claude (⌘Q) and open it again to finish. Keep SkySheet open until \
                Claude has quit: Claude can overwrite its settings while it runs, and SkySheet adds itself back as Claude quits.
                """)
            : String(localized: "Removed from Claude's settings. Quit Claude (⌘Q) to finish, and keep SkySheet open until it has quit.")
    }

    /// Claude 退出了：这次运行里点过连接或断开，就照要的结果再写一遍（它开着时可能拿内存里的那份把文件盖掉了）。
    private func claudeQuit() {
        guard let connecting = pending else { return }
        pending = nil
        if write(connecting) {
            message = connecting ? Self.connected : String(localized: "Disconnected.")
        }
        refresh()
    }

    /// 按要的结果改配置文件（已经是这样就不写）；改不了的话 message 里写明原因，返回 false。
    private func write(_ connecting: Bool) -> Bool {
        do {
            if connecting {
                guard let helper = AIHelper.url?.path else { return false }
                try AIClientConfig.update(at: configPath) { data throws(AIClientConfig.FormatError) in
                    try ClaudeDesktopConfig.connecting(helper: helper, in: data)
                }
            } else {
                try AIClientConfig.update(at: configPath, ClaudeDesktopConfig.disconnecting(in:))
            }
            return true
        } catch let error as AIClientConfig.FormatError {
            message = String(localized: "Could not update Claude's settings: \(error.message)")
        } catch {
            message = String(localized: "Could not update Claude's settings: \(error.localizedDescription)")
        }
        return false
    }

    private static var connected: String {
        String(localized: """
            Connected. Open Claude to use SkySheet in its chats. It asks before each SkySheet tool until you choose \
            Always allow, in the prompt or for all of SkySheet's tools at once in Claude's Connectors settings.
            """)
    }
}
