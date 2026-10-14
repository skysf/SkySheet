import AppKit
import SkySheetMCPKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// skysheet-mcp 在后台把 App 拉起来的（设计 9.1 节）：没人看着，不弹「打开」面板，恢复副本的提示等用户自己切过来再问。
    private let launchedByAI = CommandLine.arguments.contains(MCPBridge.launchedByAIArgument)

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 文档控制器要在启动完成前就有：从 Finder 双击打开的文件，系统在这之后马上交给它。
        _ = NSDocumentController.shared
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let request = SnapshotRequest(arguments: CommandLine.arguments) {
            SnapshotRenderer.run(request)
            return
        }
        // AI 的通道：Claude Code 启动的 skysheet-mcp 连这个 socket（设计第三节）。
        AIBridgeServer.shared.start()
        // 第五道保险：上次没正常退出留下的恢复副本，先问要不要恢复；然后每 30 秒写一次。
        RecoveryCoordinator.shared.start(askNow: !launchedByAI)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AIBridgeServer.shared.stop()
        RecoveryCoordinator.shared.drain()
    }

    /// 从访达打开、拖到 Dock 图标上的文件都走这里，交给文档控制器。截图模式下一律不开（见 SnapshotRequest）。
    func application(_ application: NSApplication, open urls: [URL]) {
        guard SnapshotRequest(arguments: CommandLine.arguments) == nil else { return }
        for url in urls {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
    }

    /// 关掉最后一个窗口不退出（设计 8.3 节：M4 起 AI 下一次调用还要用）。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 系统只在「没带文件启动」和「点 Dock 图标时没有窗口」这两种时候问要不要开空文档。
    /// 只看不建：不开空文档，改成弹「打开」面板。不能在启动完成后自己判断「有没有文档」再弹：用 open 命令或从访达
    /// 打开文件时，文件来得比那更晚，结果面板和文档窗口一起出来（2026-10-08 启动测试抓到的）。
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        SnapshotRequest(arguments: CommandLine.arguments) == nil && !launchedByAI
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.present()
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        NSDocumentController.shared.openDocument(nil)
        return true
    }
}
