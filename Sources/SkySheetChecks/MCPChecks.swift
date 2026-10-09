import Foundation
import SkySheetCore
import SkySheetMCPKit

/// 小程序（skysheet-mcp）说的 MCP 对不对（设计第十二节第 6 条，照搬 SrtFlow 的检查）：真的把它当子进程起起来，
/// 从 stdin 喂消息、读 stdout，旁边起一个假 App 在临时 socket 上听，看工具调用有没有原样转过去、回答有没有原样回来。
/// 两代客户端都验。外加给模型看的文字：总说明和每个工具的说明都在 2,048 个字符以内、没有汉字、目录里有每个工具名。
@MainActor
func mcpChecks() {
    group("mcp: texts the model reads") {
        let instructions = MCPInstructions.text
        let limit = 2_048   // Claude Code 只读这么多（按 UTF-16 数，同它的 JavaScript 长度），超了静默截掉
        check(instructions.utf16.count <= limit, "instructions fit in \(limit) characters (\(instructions.utf16.count))")
        let opening = String(instructions.prefix(512))
        for name in ["get_status", "describe_sheet", "add_sheet", "write_cells"] {
            check(opening.contains(name), "the first 512 characters already name \(name)")
        }
        for tool in MCPToolName.allCases {
            check(instructions.range(of: "\\b\(tool.rawValue)\\b", options: .regularExpression) != nil,
                  "the catalog names \(tool.rawValue)")
            let description = tool.definition.description
            check(description.utf16.count <= limit, "\(tool.rawValue) description fits (\(description.utf16.count))")
        }
        let catalog = MCPToolName.listJSON.encodedString()
        check(catalog.count <= 40_000, "the tool list stays small (\(catalog.count) characters)")
        let han = (instructions + catalog).unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }
        check(han.isEmpty, "English only for the model (found \(String(String.UnicodeScalarView(han.prefix(5)))))")
        checkEqual(MCPVocabulary.numberFormatPresets, FormatPreset.allCases.map(\.rawValue), "presets match FormatPreset")
        for tool in MCPToolName.allCases {
            let schema = tool.definition.inputSchema
            let properties = schema["properties"]?.objectValue ?? [:]
            for required in schema["required"]?.arrayValue ?? [] {
                check(properties[required.stringValue ?? ""] != nil, "\(tool.rawValue): required \(required) is a property")
            }
        }
    }

    guard let helper = helperURL() else {
        group("mcp: helper") { fail("skysheet-mcp is not next to SkySheetChecks; build with swift build first") }
        return
    }
    let app: FakeApp
    do {
        app = try FakeApp()
    } catch {
        group("mcp: helper") { fail("fake app could not listen: \(error)") }
        return
    }

    group("mcp: legacy clients (initialize first)") {
        let (messages, raw) = talk(helper, socket: app.path, [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"check-client","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":"abc","method":"tools/call","params":{"name":"get_status","arguments":{}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"no_such_tool","arguments":{}}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"no/such/method"}"#,
            #"not json"#,
            #"{"jsonrpc":"2.0","id":7,"method":"ping"}"#,
        ])
        let initialize = reply(messages, id: 1)?["result"]
        checkEqual(initialize?["protocolVersion"]?.stringValue, "2025-06-18", "a known legacy version is echoed")
        checkEqual(initialize?["serverInfo"]?["name"]?.stringValue, "skysheet", "server name")
        checkEqual(initialize?["instructions"]?.stringValue, MCPInstructions.text, "instructions sent")
        let tools = reply(messages, id: 2)?["result"]?["tools"]?.arrayValue ?? []
        checkEqual(tools.compactMap { $0["name"]?.stringValue }, MCPToolName.allCases.map(\.rawValue), "tools/list order")
        let readOnly = tools.filter { $0["annotations"]?["readOnlyHint"]?.boolValue == true }.compactMap { $0["name"]?.stringValue }
        checkEqual(readOnly, ["get_status", "describe_sheet", "read_range", "query", "evaluate", "export_sheet", "show"],
                   "read-only tools are marked")
        checkEqual(reply(messages, id: "abc")?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue,
                   "echo:get_status", "tools/call is forwarded and the app's answer comes back")
        checkEqual(app.requests.first?.client, "check-client", "the client name reaches the app")
        checkEqual(reply(messages, id: 4)?["error"]?["code"]?.intValue, -32602, "unknown tool")
        checkEqual(reply(messages, id: 5)?["error"]?["code"]?.intValue, -32601, "unknown method")
        check(messages.contains { $0["error"]?["code"]?.intValue == -32700 }, "parse error")
        check(raw.contains(#""id":7"#), "integer ids stay integers")
        checkEqual(messages.count, 7, "one answer per request, none for the notification")
    }

    group("mcp: modern clients (version in every request)") {
        let meta = #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"modern-client","version":"2"}}"#
        let (messages, _) = talk(helper, socket: app.path, [
            #"{"jsonrpc":"2.0","id":10,"method":"server/discover","params":{\#(meta)}}"#,
            #"{"jsonrpc":"2.0","id":11,"method":"tools/list","params":{\#(meta)}}"#,
            #"{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{\#(meta),"name":"read_range","arguments":{"range":"A1"}}}"#,
            #"{"jsonrpc":"2.0","id":13,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"1900-01-01"}}}"#,
        ])
        let discover = reply(messages, id: 10)?["result"]
        let versions = discover?["supportedVersions"]?.arrayValue?.compactMap(\.stringValue) ?? []
        check(versions.contains("2026-07-28") && versions.contains("2025-11-25"), "discover lists both eras")
        checkEqual(discover?["resultType"]?.stringValue, "complete", "resultType")
        check(reply(messages, id: 11)?["result"]?["ttlMs"] != nil, "tools/list is cacheable")
        checkEqual(reply(messages, id: 12)?["result"]?["resultType"]?.stringValue, "complete", "tool results carry resultType")
        checkEqual(app.requests.last?.client, "modern-client", "client name from _meta")
        checkEqual(app.requests.last?.arguments["range"]?.stringValue, "A1", "arguments forwarded as they are")
        checkEqual(reply(messages, id: 13)?["error"]?["code"]?.intValue, -32022, "unknown version refused")
    }

    group("mcp: SkySheet not running") {
        let (messages, _) = talk(helper, socket: "/tmp/skysheet-check-nobody-\(getpid()).sock", [
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_status","arguments":{}}}"#,
        ])
        let result = reply(messages, id: 1)?["result"]
        checkEqual(result?["isError"]?.boolValue, true, "a tool result, not a protocol error")
        check(result?["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("not running") == true, "says why")
    }
}

/// 自检程序和小程序编在同一个文件夹里（swift build 一起编）。
private func helperURL() -> URL? {
    guard let checks = Bundle.main.executableURL else { return nil }
    let url = checks.deletingLastPathComponent().appendingPathComponent("skysheet-mcp")
    return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
}

/// 起一次小程序，喂这几行，读回所有回答（按行）。原始文本也一并返回（验 id 的写法）。
private func talk(_ helper: URL, socket: String, _ lines: [String]) -> (messages: [JSONValue], raw: String) {
    let process = Process()
    process.executableURL = helper
    var environment = ProcessInfo.processInfo.environment
    environment["SKYSHEET_MCP_SOCKET"] = socket
    environment["SKYSHEET_MCP_NO_LAUNCH"] = "1"
    process.environment = environment
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    guard (try? process.run()) != nil else { return ([], "") }
    input.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    try? input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let raw = String(decoding: data, as: UTF8.self)
    return (raw.split(separator: "\n").compactMap { try? JSONValue.decode(Data($0.utf8)) }, raw)
}

private func reply(_ messages: [JSONValue], id: JSONValue) -> JSONValue? {
    messages.first { $0["id"] == id }
}

/// 假 App：收到什么工具就回「echo:工具名」，记下每次调用。
private final class FakeApp: @unchecked Sendable {
    let path: String
    private let lock = NSLock()
    private var seen: [MCPBridge.Request] = []

    init() throws {
        // socket 路径不能超过 103 个字节：临时目录太长，放 /tmp。
        path = "/tmp/skysheet-check-\(getpid()).sock"
        let fd = try MCPUnixSocket.listen(path: path)
        Thread { [weak self] in
            while let client = MCPUnixSocket.accept(fd) {
                guard let line = try? MCPUnixSocket.readLine(client),
                      let request = try? JSONDecoder().decode(MCPBridge.Request.self, from: line) else {
                    close(client)
                    continue
                }
                self?.record(request)
                let response = MCPBridge.Response(id: request.id, result: MCPBridge.textResult("echo:\(request.tool)"))
                if let data = try? JSONEncoder().encode(response) { try? MCPUnixSocket.writeLine(client, data) }
                close(client)
            }
        }.start()
    }

    deinit {
        unlink(path)
    }

    private func record(_ request: MCPBridge.Request) {
        lock.lock()
        seen.append(request)
        lock.unlock()
    }

    var requests: [MCPBridge.Request] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }
}
