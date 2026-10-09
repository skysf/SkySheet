import AppKit
import SkySheetFiles
import SwiftUI

/// 设置窗口（⌘,）：连接 Claude Code（设计 9.5 节）、打开备份文件夹（第十节第 4 条）。
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
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    private var setup: ClaudeCodeSetup { ClaudeCodeSetup.shared }

    var body: some View {
        Form {
            Section("Claude Code") {
                Text("Let Claude Code read your workbooks and write its results into new sheets. Your original sheets stay read-only to it, and nothing reaches your files until you press ⌘S.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if setup.helperURL == nil {
                    Text("This copy of SkySheet has no AI helper inside, so Claude Code cannot connect to it.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    LabeledContent("Status") {
                        HStack(spacing: 8) {
                            statusLabel
                            action
                        }
                        .controlSize(.small)
                        .disabled(setup.busy)
                    }
                }
                if let message = setup.message {
                    Text(verbatim: message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
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
    private var statusLabel: some View {
        switch setup.status {
        case .connected: Text("Connected").foregroundStyle(.green)
        case .connectedAsking: Text("Connected · asks before each tool").foregroundStyle(.orange)
        case .connectedElsewhere: Text("Connected to another copy of SkySheet").foregroundStyle(.orange)
        case .notConnected: Text("Not connected").foregroundStyle(.secondary)
        case .notInstalled: Text("Claude Code not found").foregroundStyle(.tertiary)
        }
    }

    /// 一行只放一个按钮（SrtFlow 的经验）：连上了是「断开」，没连上是「连接」，没有命令行时是「复制一段话」。
    @ViewBuilder
    private var action: some View {
        switch setup.status {
        case .connected:
            Button("Disconnect") { Task { await setup.disconnect() } }
        case .notConnected, .connectedAsking, .connectedElsewhere, .notInstalled:
            if setup.cli != nil {
                Button("Connect") { Task { await setup.connect() } }
            } else {
                Button("Copy Setup Prompt") { setup.copyPrompt() }
                    .help("Copy a message you can paste into Claude Code so it connects SkySheet itself")
            }
        }
    }
}
