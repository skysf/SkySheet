import AppKit
import SkySheetFiles
import SwiftUI

/// 设置窗口（⌘,）：连接 Claude Code 和 Claude 桌面版（设计 9.5 节）、打开备份文件夹（第十节第 4 条）。
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
        window.title = String(localized: "SkySheet Settings")
        window.styleMask = [.titled, .closable]
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func present() {
        ClaudeCodeSetup.shared.refresh()
        ClaudeDesktopSetup.shared.refresh()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    private var code: ClaudeCodeSetup { ClaudeCodeSetup.shared }
    private var desktop: ClaudeDesktopSetup { ClaudeDesktopSetup.shared }

    var body: some View {
        Form {
            Section("AI") {
                Text("Let Claude read your workbooks and write its results into new sheets. Your original sheets stay read-only to it, and nothing reaches your files until you press ⌘S. Claude Desktop is for chats in the Claude app; its Code tab uses the Claude Code connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if AIHelper.url == nil {
                    Text("This copy of SkySheet has no AI helper inside, so AI apps cannot connect to it.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    LabeledContent("Claude Code") {
                        HStack(spacing: 8) {
                            statusLabel(code.status)
                            codeAction
                        }
                        .controlSize(.small)
                        .disabled(code.busy)
                    }
                    note(code.message)
                    LabeledContent("Claude Desktop") {
                        HStack(spacing: 8) {
                            statusLabel(desktop.status)
                            desktopAction
                        }
                        .controlSize(.small)
                    }
                    note(desktop.message)
                }
            }
            Section("Backups") {
                Text("Before SkySheet first overwrites a file, it keeps a copy of the original (the last 10 per file).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Backups Folder") {
                    try? FileManager.default.createDirectory(at: SafetyFolders.backups, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(SafetyFolders.backups)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func note(_ message: String?) -> some View {
        if let message {
            Text(verbatim: message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func statusLabel(_ status: AIClientStatus) -> some View {
        switch status {
        case .connected: Text("Connected").foregroundStyle(.green)
        case .connectedAsking: Text("Connected · asks before each tool").foregroundStyle(.orange)
        case .connectedElsewhere: Text("Connected to another copy of SkySheet").foregroundStyle(.orange)
        case .restartNeeded: Text("Restart Claude to finish").foregroundStyle(.orange)
        case .notConnected: Text("Not connected").foregroundStyle(.secondary)
        case .notInstalled: Text("Not installed").foregroundStyle(.tertiary)
        }
    }

    /// 一行只放一个按钮（SrtFlow 的经验）：连上了是「断开」，没连上是「连接」，没有命令行时是「复制一段话」。
    @ViewBuilder
    private var codeAction: some View {
        switch code.status {
        case .connected:
            Button("Disconnect") { Task { await code.disconnect() } }
        case .notConnected, .connectedAsking, .connectedElsewhere, .notInstalled, .restartNeeded:
            if code.cli != nil {
                Button("Connect") { Task { await code.connect() } }
            } else {
                Button("Copy Setup Prompt") { code.copyPrompt() }
                    .help("Copy a message you can paste into Claude Code so it connects SkySheet itself")
            }
        }
    }

    /// 等着 Claude 重启的时候也只放一个按钮：要连上的那一次给「断开」（反悔），要断开的给「连接」。没装就不放。
    @ViewBuilder
    private var desktopAction: some View {
        switch desktop.status {
        case .connected, .restartNeeded(connecting: true):
            Button("Disconnect") { desktop.disconnect() }
        case .notConnected, .connectedElsewhere, .connectedAsking, .restartNeeded(connecting: false):
            Button("Connect") { desktop.connect() }
                .help("Add SkySheet to the Claude app's settings so its chats can use SkySheet")
        case .notInstalled:
            EmptyView()
        }
    }
}
