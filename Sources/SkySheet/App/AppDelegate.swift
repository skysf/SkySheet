import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
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
        // 第五道保险：上次没正常退出留下的恢复副本，先问要不要恢复；然后每 30 秒写一次。
        RecoveryCoordinator.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
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
        SnapshotRequest(arguments: CommandLine.arguments) == nil
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        NSDocumentController.shared.openDocument(nil)
        return true
    }
}

/// 菜单栏用代码搭（没有 nib）。界面只用英文（设计第 22 条），文字都走 String(localized:)，以后加中文只是补翻译。
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        let appName = "SkySheet"
        main.addItem(submenu(appName, [
            item(String(localized: "About \(appName)"), #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item(String(localized: "Hide \(appName)"), #selector(NSApplication.hide(_:)), key: "h"),
            item(String(localized: "Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), key: "h",
                 modifiers: [.command, .option]),
            item(String(localized: "Show All"), #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item(String(localized: "Quit \(appName)"), #selector(NSApplication.terminate(_:)), key: "q"),
        ]))
        main.addItem(submenu(String(localized: "File"), [
            item(String(localized: "Open…"), #selector(NSDocumentController.openDocument(_:)), key: "o"),
            .separator(),
            item(String(localized: "Close"), #selector(NSWindow.performClose(_:)), key: "w"),
            item(String(localized: "Save"), #selector(NSDocument.save(_:)), key: "s"),
            item(String(localized: "Save As…"), #selector(NSDocument.saveAs(_:)), key: "s", modifiers: [.command, .shift]),
            item(String(localized: "Revert to Saved"), #selector(NSDocument.revertToSaved(_:))),
        ]))
        main.addItem(submenu(String(localized: "Edit"), [
            item(String(localized: "Undo"), #selector(SpreadsheetView.undo(_:)), key: "z"),
            item(String(localized: "Redo"), #selector(SpreadsheetView.redo(_:)), key: "z", modifiers: [.command, .shift]),
            .separator(),
            item(String(localized: "Cut"), #selector(SpreadsheetView.cut(_:)), key: "x"),
            item(String(localized: "Copy"), #selector(SpreadsheetView.copy(_:)), key: "c"),
            item(String(localized: "Paste"), #selector(SpreadsheetView.paste(_:)), key: "v"),
            item(String(localized: "Delete"), #selector(SpreadsheetView.delete(_:))),
            item(String(localized: "Select All"), #selector(NSResponder.selectAll(_:)), key: "a"),
        ]))
        main.addItem(submenu(String(localized: "Sheet"), [
            item(String(localized: "Rename Sheet…"), #selector(SpreadsheetView.renameSheet(_:))),
            item(String(localized: "Duplicate Sheet"), #selector(SpreadsheetView.duplicateSheet(_:))),
            .separator(),
            item(String(localized: "Delete Sheet"), #selector(SpreadsheetView.deleteSheet(_:))),
        ]))
        main.addItem(submenu(String(localized: "View"), [
            item(String(localized: "Actual Size"), #selector(SpreadsheetView.resetZoom(_:)), key: "0"),
            item(String(localized: "Zoom In"), #selector(SpreadsheetView.zoomIn(_:)), key: "+"),
            item(String(localized: "Zoom Out"), #selector(SpreadsheetView.zoomOut(_:)), key: "-"),
        ]))
        let windowMenu = submenu(String(localized: "Window"), [
            item(String(localized: "Minimize"), #selector(NSWindow.performMiniaturize(_:)), key: "m"),
            item(String(localized: "Zoom"), #selector(NSWindow.performZoom(_:))),
            .separator(),
            item(String(localized: "Bring All to Front"), #selector(NSApplication.arrangeInFront(_:))),
        ])
        main.addItem(windowMenu)
        NSApp.windowsMenu = windowMenu.submenu
        return main
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    private static func item(_ title: String, _ action: Selector, key: String = "",
                             modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        return item
    }
}
