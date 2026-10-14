import Foundation
import SkySheetMCPKit

/// 连接 Claude 桌面版时改它的 claude_desktop_config.json（设计 9.5 节）：只插进、换掉或删掉 skysheet 那一项，别的字节
/// 一个不动（文件里大半是桌面版自己的偏好）；格式不对一个字节都不写；备份的权限跟着原文件（它只许自己读）。
@MainActor
func claudeDesktopConfigChecks() {
    let helper = "/Applications/SkySheet.app/Contents/Helpers/skysheet-mcp"
    let connect = { (data: Data?) throws(AIClientConfig.FormatError) -> Data? in
        try ClaudeDesktopConfig.connecting(helper: helper, in: data)
    }
    let disconnect = ClaudeDesktopConfig.disconnecting(in:)

    group("claude desktop: Claude's own layout is kept") {
        // 桌面版自己写的样子：两格缩进、末尾不换行、大半是它的 preferences。
        let original = """
            {
              "coworkUserFilesPath": "/Users/me/Claude",
              "preferences": {
                "sidebarMode": "epitaxy",
                "localAgentModeTrustedFolders": [
                  "/Users/me/Projects"
                ],
                "keepAwakeEnabled": true
              }
            }
            """
        let connected = """
            {
              "coworkUserFilesPath": "/Users/me/Claude",
              "preferences": {
                "sidebarMode": "epitaxy",
                "localAgentModeTrustedFolders": [
                  "/Users/me/Projects"
                ],
                "keepAwakeEnabled": true
              },
              "mcpServers": {
                "skysheet": {
                  "command": "/Applications/SkySheet.app/Contents/Helpers/skysheet-mcp",
                  "args": []
                }
              }
            }
            """
        checkEdit(connect, original, connected, "mcpServers is added at the end, written the way Claude writes it")
        checkEqual(AIClientConfig.command(in: Data(connected.utf8)), helper, "reads which helper Claude starts")
        checkEdit(connect, connected, nil, "already connected: nothing to write")
        checkEdit(disconnect, original, nil, "not connected: nothing to remove")
        checkEdit(disconnect, nil, nil, "no file: nothing to remove")

        let others = """
            {
              "mcpServers": {
                "other": {
                  "command": "/usr/local/bin/other-mcp",
                  "args": [
                    "--stdio"
                  ]
                }
              },
              "preferences": {
                "sidebarMode": "epitaxy"
              }
            }
            """
        let withSkySheet = """
            {
              "mcpServers": {
                "other": {
                  "command": "/usr/local/bin/other-mcp",
                  "args": [
                    "--stdio"
                  ]
                },
                "skysheet": {
                  "command": "/Applications/SkySheet.app/Contents/Helpers/skysheet-mcp",
                  "args": []
                }
              },
              "preferences": {
                "sidebarMode": "epitaxy"
              }
            }
            """
        checkEdit(connect, others, withSkySheet, "joins the other servers")
        checkEdit(disconnect, withSkySheet, others, "disconnecting gives back the same bytes")

        let empty = """
            {
              "mcpServers": {},
              "preferences": {
                "sidebarMode": "epitaxy"
              }
            }
            """
        let filled = """
            {
              "mcpServers": {
                "skysheet": {
                  "command": "/Applications/SkySheet.app/Contents/Helpers/skysheet-mcp",
                  "args": []
                }
              },
              "preferences": {
                "sidebarMode": "epitaxy"
              }
            }
            """
        checkEdit(connect, empty, filled, "an empty mcpServers gets the entry on its own lines")
        checkEdit(disconnect, filled, empty, "the last server out leaves {}")

        let fresh = """
            {
              "mcpServers": {
                "skysheet": {
                  "command": "/Applications/SkySheet.app/Contents/Helpers/skysheet-mcp",
                  "args": []
                }
              }
            }
            """
        checkEdit(connect, nil, fresh, "a missing file is written the way Claude writes it")
        checkEdit(connect, "{}", fresh, "an empty object too")
    }

    group("claude desktop: another copy of SkySheet") {
        // App 挪过位置：只换 command，用户加的 env 留着。
        checkEdit(connect, """
            {
              "mcpServers": {
                "skysheet": {
                  "command": "/Users/me/Downloads/SkySheet.app/Contents/Helpers/skysheet-mcp",
                  "args": [],
                  "env": {
                    "DEBUG": "1"
                  }
                }
              }
            }
            """, """
            {
              "mcpServers": {
                "skysheet": {
                  "command": "/Applications/SkySheet.app/Contents/Helpers/skysheet-mcp",
                  "args": [],
                  "env": {
                    "DEBUG": "1"
                  }
                }
              }
            }
            """, "only the command is swapped")
        // 不像样的一项（不是对象、没有 command）整个换成新写的。
        let replaced = """
            {
              "mcpServers": {
                "skysheet": {
                  "command": "/Applications/SkySheet.app/Contents/Helpers/skysheet-mcp",
                  "args": []
                }
              }
            }
            """
        checkEdit(connect, "{\n  \"mcpServers\": {\n    \"skysheet\": \"broken\"\n  }\n}", replaced, "a broken entry is rewritten")
        checkEdit(connect, "{\n  \"mcpServers\": {\n    \"skysheet\": {}\n  }\n}", replaced, "an entry without a command too")
    }

    group("claude desktop: one-line configs") {
        checkEdit(connect, #"{"mcpServers":{"other":{"command":"x"}}}"#,
                  #"{"mcpServers":{"other":{"command":"x"},"skysheet":{"command":"/Applications/SkySheet.app/Contents/Helpers/skysheet-mcp","args":[]}}}"#,
                  "compact files stay compact")
        checkEdit(disconnect, #"{"mcpServers": {"skysheet": {"command": "a"}, "other": {"command": "x"}}}"#,
                  #"{"mcpServers": {"other": {"command": "x"}}}"#, "removed from the front")
        checkEdit(disconnect, #"{"mcpServers":{"skysheet":{"command":"a"},"x":{"command":"b"},"skysheet":{"command":"c"}}}"#,
                  #"{"mcpServers":{"x":{"command":"b"}}}"#, "every copy is removed")
        // 同一个键写了两次：JavaScript 认最后一个，看的、改的也是最后一个。
        checkEdit(connect, #"{"mcpServers":{"skysheet":{"command":"old"},"skysheet":{"command":"/Applications/SkySheet.app/Contents/Helpers/skysheet-mcp"}}}"#,
                  nil, "the last duplicate decides")
    }

    group("claude desktop: malformed configs are left alone") {
        checkRefused(connect, "{not json", "not valid JSON")
        checkRefused(connect, "[]", "not valid JSON")
        checkRefused(connect, "{\n  // a comment\n  \"mcpServers\": {}\n}", "not valid JSON")
        checkRefused(connect, #"{"mcpServers":[]}"#, "not an object")
        checkRefused(connect, #"{"mcpServers":"skysheet"}"#, "not an object")
        checkRefused(disconnect, #"{"mcpServers":["skysheet"]}"#, "not an object")
    }

    group("claude desktop: the config file on disk") {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("skysheet-desktop-check-\(getpid())")
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // 桌面版的配置只许自己读：备份也一样，改完还是一样。
        let path = ClaudeDesktopConfig.path(home: folder.path)
        let original = Data("{\n  \"mcpServers\": {},\n  \"preferences\": {\n    \"keepAwakeEnabled\": true\n  }\n}".utf8)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try original.write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        try AIClientConfig.update(at: path, connect)
        checkEqual(AIClientConfig.command(in: FileManager.default.contents(atPath: path)), helper, "entry written")
        checkEqual(attribute(.posixPermissions, path) as? Int, 0o600, "file permissions kept")
        checkEqual(FileManager.default.contents(atPath: path + ".skysheet-backup"), original, "the original is backed up first")
        checkEqual(attribute(.posixPermissions, path + ".skysheet-backup") as? Int, 0o600, "the backup is private too")
        let written = attribute(.modificationDate, path) as? Date
        try AIClientConfig.update(at: path, connect)
        checkEqual(attribute(.modificationDate, path) as? Date, written, "connecting twice does not touch the file")
        try AIClientConfig.update(at: path, disconnect)
        checkEqual(FileManager.default.contents(atPath: path), original, "disconnecting restores the file byte for byte")
    }
}
