import Foundation
import SkySheetMCPKit

/// 连接 Claude Code 时改它的配置文件（设计 9.5 节）：读得对；settings.json 只插进或删掉那一条，别的字节一个不动
/// （v0.3.0 整份重写过，键全被排序、空格全变，v0.3.1 修掉，这里按字节钉住）。外加真的文件：先备份、没有要改的不写、
/// 权限和软链接留着。
@MainActor
func claudeCodeConfigChecks() {
    group("claude code: reading the config") {
        let config = Data(#"{"mcpServers":{"skysheet":{"command":"/Applications/SkySheet.app/Contents/Helpers/skysheet-mcp"},"other":{"command":"x"}},"theme":"dark"}"#.utf8)
        checkEqual(ClaudeCodeConfig.command(in: config), "/Applications/SkySheet.app/Contents/Helpers/skysheet-mcp",
                   "reads which helper Claude Code starts")
        checkEqual(ClaudeCodeConfig.command(in: Data("{}".utf8)), nil, "not connected")
        check(ClaudeCodeConfig.allows(in: Data(#"{"permissions":{"allow":["Bash(ls:*)","mcp__skysheet"]}}"#.utf8)), "allowed")
        check(!ClaudeCodeConfig.allows(in: Data(#"{"permissions":{"allow":["mcp__skysheet__get_status"]}}"#.utf8)),
              "only the exact rule counts")
        check(!ClaudeCodeConfig.allows(in: nil), "no settings file")
        check(ClaudeCodeConfig.setupPrompt(helper: "/x/skysheet-mcp").contains("claude mcp add --scope user skysheet -- \"/x/skysheet-mcp\""),
              "the copy-paste prompt has the command")
    }

    group("claude code: settings keep their layout") {
        // Claude Code 自己写的样子：键不按字母排、两格缩进、末尾有换行、路径里的 / 不转义。
        let original = """
            {
              "statusLine": {
                "type": "command",
                "command": "/Users/me/.claude/statusline.sh"
              },
              "permissions": {
                "allow": [
                  "Bash(ls:*)",
                  "mcp__srtflow"
                ],
                "defaultMode": "auto"
              },
              "model": "opus"
            }

            """
        let connected = """
            {
              "statusLine": {
                "type": "command",
                "command": "/Users/me/.claude/statusline.sh"
              },
              "permissions": {
                "allow": [
                  "Bash(ls:*)",
                  "mcp__srtflow",
                  "mcp__skysheet"
                ],
                "defaultMode": "auto"
              },
              "model": "opus"
            }

            """
        checkEdit(ClaudeCodeConfig.allowing(in:), original, connected, "only the rule is added")
        checkEdit(ClaudeCodeConfig.disallowing(in:), connected, original, "disconnecting gives back the same bytes")
        checkEdit(ClaudeCodeConfig.allowing(in:), connected, nil, "already allowed: nothing to write")
        checkEdit(ClaudeCodeConfig.disallowing(in:), original, nil, "not allowed: nothing to write")

        let emptyList = """
            {
              "permissions": {
                "allow": [],
                "defaultMode": "auto"
              }
            }
            """
        let filledList = """
            {
              "permissions": {
                "allow": [
                  "mcp__skysheet"
                ],
                "defaultMode": "auto"
              }
            }
            """
        checkEdit(ClaudeCodeConfig.allowing(in:), emptyList, filledList, "an empty list gets the rule on its own line")
        checkEdit(ClaudeCodeConfig.disallowing(in:), filledList, emptyList, "the last rule out leaves []")

        checkEdit(ClaudeCodeConfig.allowing(in:), """
            {
              "permissions": {
                "defaultMode": "auto"
              }
            }
            """, """
            {
              "permissions": {
                "defaultMode": "auto",
                "allow": [
                  "mcp__skysheet"
                ]
              }
            }
            """, "a missing allow list is added at the end")
        // v0.3.0 写出来的样子（JSONSerialization：冒号两边有空格）：新写的照它的冒号。
        checkEdit(ClaudeCodeConfig.allowing(in:), """
            {
              "model" : "opus"
            }
            """, """
            {
              "model" : "opus",
              "permissions" : {
                "allow" : [
                  "mcp__skysheet"
                ]
              }
            }
            """, "missing permissions follow the file's colons")
        checkEdit(ClaudeCodeConfig.allowing(in:), "{\r\n\t\"model\": \"opus\"\r\n}\r\n",
                  "{\r\n\t\"model\": \"opus\",\r\n\t\"permissions\": {\r\n\t\t\"allow\": [\r\n\t\t\t\"mcp__skysheet\"\r\n\t\t]\r\n\t}\r\n}\r\n",
                  "tabs and CRLF are kept")
        let fresh = "{\n  \"permissions\": {\n    \"allow\": [\n      \"mcp__skysheet\"\n    ]\n  }\n}"
        checkEdit(ClaudeCodeConfig.allowing(in:), nil, fresh + "\n", "a missing file is written the way Claude Code would")
        checkEdit(ClaudeCodeConfig.allowing(in:), "{}\n", fresh + "\n", "an empty object too")
        checkEdit(ClaudeCodeConfig.disallowing(in:), nil, nil, "no file: nothing to remove")
    }

    group("claude code: one-line settings") {
        checkEdit(ClaudeCodeConfig.allowing(in:), #"{"model":"opus"}"#,
                  #"{"model":"opus","permissions":{"allow":["mcp__skysheet"]}}"#, "compact files stay compact")
        checkEdit(ClaudeCodeConfig.allowing(in:), #"{"permissions": {"allow": ["Bash(ls:*)"]}}"#,
                  #"{"permissions": {"allow": ["Bash(ls:*)", "mcp__skysheet"]}}"#, "spaced files stay spaced")
        checkEdit(ClaudeCodeConfig.allowing(in:), #"{"note": "Grüße 🙂", "permissions": {"allow": []}}"#,
                  #"{"note": "Grüße 🙂", "permissions": {"allow": ["mcp__skysheet"]}}"#, "positions count bytes, not characters")
        checkEdit(ClaudeCodeConfig.disallowing(in:), #"{"permissions": {"allow": ["a", "mcp__skysheet", "b"]}}"#,
                  #"{"permissions": {"allow": ["a", "b"]}}"#, "removed from the middle")
        checkEdit(ClaudeCodeConfig.disallowing(in:), #"{"permissions": {"allow": ["mcp__skysheet", "a"]}}"#,
                  #"{"permissions": {"allow": ["a"]}}"#, "removed from the front")
        checkEdit(ClaudeCodeConfig.disallowing(in:), #"{"permissions":{"allow":["mcp__skysheet","a","mcp__skysheet"]}}"#,
                  #"{"permissions":{"allow":["a"]}}"#, "every copy is removed")
        // 转义写法也认得（s = s，_ = _）。
        let escaped = #"{"permissions":{"allow":["mcp__skysheet"]}}"#
        check(ClaudeCodeConfig.allows(in: Data(escaped.utf8)), "escaped rule is recognized")
        checkEdit(ClaudeCodeConfig.allowing(in:), escaped, nil, "escaped rule counts as present")
        checkEdit(ClaudeCodeConfig.disallowing(in:), escaped, #"{"permissions":{"allow":[]}}"#, "escaped rule is removed")
        // 同一个键写了两次：JavaScript 认最后一个，改的也是最后一个。
        checkEdit(ClaudeCodeConfig.allowing(in:), #"{"permissions":{"allow":["a"]},"permissions":{"allow":["b"]}}"#,
                  #"{"permissions":{"allow":["a"]},"permissions":{"allow":["b","mcp__skysheet"]}}"#, "the last duplicate wins")
    }

    group("claude code: malformed settings are left alone") {
        checkRefused(ClaudeCodeConfig.allowing(in:), #"{"permissions":{"allow":"everything"}}"#, "not a list")
        checkRefused(ClaudeCodeConfig.allowing(in:), #"{"permissions":{"allow":["a",1]}}"#, "not a list")
        checkRefused(ClaudeCodeConfig.disallowing(in:), #"{"permissions":{"allow":"mcp__skysheet"}}"#, "not a list")
        checkRefused(ClaudeCodeConfig.allowing(in:), #"{"permissions":["mcp__skysheet"]}"#, "not an object")
        checkRefused(ClaudeCodeConfig.allowing(in:), "{not json", "not valid JSON")
        checkRefused(ClaudeCodeConfig.allowing(in:), #"["mcp__skysheet"]"#, "not valid JSON")
        checkRefused(ClaudeCodeConfig.allowing(in:), "{\n  // a comment\n  \"model\": \"opus\"\n}\n", "not valid JSON")
    }

    group("claude code: the settings file on disk") {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("skysheet-settings-check-\(getpid())")
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let missing = folder.appendingPathComponent("new/settings.json").path
        try ClaudeCodeConfig.updateSettings(at: missing, ClaudeCodeConfig.allowing(in:))
        check(ClaudeCodeConfig.allows(in: FileManager.default.contents(atPath: missing)), "a missing file is created")
        check(!FileManager.default.fileExists(atPath: missing + ".skysheet-backup"), "nothing to back up")

        // 断开只删这一条：连接时补上的空 allow 列表留着，所以拿本来就有列表的文件验「一个字节不差」。
        let path = folder.appendingPathComponent("settings.json").path
        let original = Data("{\n  \"permissions\": {\n    \"allow\": [\n      \"Bash(ls:*)\"\n    ]\n  }\n}\n".utf8)
        try original.write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        try ClaudeCodeConfig.updateSettings(at: path, ClaudeCodeConfig.allowing(in:))
        check(ClaudeCodeConfig.allows(in: FileManager.default.contents(atPath: path)), "rule written")
        checkEqual(FileManager.default.contents(atPath: path + ".skysheet-backup"), original, "the original is backed up first")
        checkEqual(attribute(.posixPermissions, path) as? Int, 0o600, "file permissions kept")
        try ClaudeCodeConfig.updateSettings(at: path, ClaudeCodeConfig.disallowing(in:))
        checkEqual(FileManager.default.contents(atPath: path), original, "disconnecting restores the file byte for byte")
        checkEqual(FileManager.default.contents(atPath: path + ".skysheet-backup"), original, "the backup keeps the first original")
        let written = attribute(.modificationDate, path) as? Date
        try ClaudeCodeConfig.updateSettings(at: path, ClaudeCodeConfig.disallowing(in:))
        checkEqual(attribute(.modificationDate, path) as? Date, written, "nothing to change: the file is not touched")

        // dotfiles 常把 settings.json 做成软链接：写进它指向的文件，链接本身留着。
        let real = folder.appendingPathComponent("dotfiles-settings.json").path
        let link = folder.appendingPathComponent("linked/settings.json").path
        try original.write(to: URL(fileURLWithPath: real))
        try FileManager.default.createDirectory(atPath: (link as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        try ClaudeCodeConfig.updateSettings(at: link, ClaudeCodeConfig.allowing(in:))
        checkEqual(try? FileManager.default.destinationOfSymbolicLink(atPath: link), real, "the link is still a link")
        check(ClaudeCodeConfig.allows(in: FileManager.default.contents(atPath: real)), "the file it points to got the rule")
    }
}

/// 改完正好是这些字节；nil 是「不用写」。
@MainActor
private func checkEdit(_ edit: (Data?) throws(ClaudeCodeConfig.FormatError) -> Data?, _ input: String?, _ expected: String?,
                       _ message: String, file: StaticString = #fileID, line: UInt = #line) {
    do {
        let output = try edit(input.map { Data($0.utf8) })
        checkEqual(output.map { String(decoding: $0, as: UTF8.self) }, expected, message, file: file, line: line)
    } catch {
        fail("\(message): \(error.message)", file: file, line: line)
    }
}

/// 格式不对的文件：报错（话里有 `reason`），不给出任何要写的东西。
@MainActor
private func checkRefused(_ edit: (Data?) throws(ClaudeCodeConfig.FormatError) -> Data?, _ input: String, _ reason: String,
                          file: StaticString = #fileID, line: UInt = #line) {
    do {
        let output = try edit(Data(input.utf8))
        fail("\(input) was not refused: \(output.map { String(decoding: $0, as: UTF8.self) } ?? "nil")", file: file, line: line)
    } catch {
        check(error.message.contains(reason), "\(input): \(error.message)", file: file, line: line)
    }
}

private func attribute(_ key: FileAttributeKey, _ path: String) -> Any? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[key]
}
