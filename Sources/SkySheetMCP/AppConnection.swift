import Foundation
import SkySheetMCPKit

// MARK: - 找到 SkySheet、把一次工具调用交给它
//
// 管什么：小程序在哪个 App 里（从自己的路径往上找 .app）、那个 App 的 socket 在哪、没开就用 `open -g` 把它拉起来
// （不抢前台）、等它开始听、把请求交过去、把回答拿回来。从 SrtFlow 搬来。
// 不管什么：MCP 协议（MCPServerCore）、工具怎么做（App）。
//
// 测试用的三个环境变量（不设就完全不生效）：
// - SKYSHEET_MCP_SOCKET：直接连这个 socket（自检里的假 App）；
// - SKYSHEET_MCP_NO_LAUNCH：连不上就报错，不去拉起 App；
// - SKYSHEET_MCP_APP：App 的路径（小程序不在 .app 里、从 .build 直接跑的时候）。

struct AppConnection {
    let appURL: URL?
    let bundleIdentifier: String
    let socketPath: String
    let appVersion: String
    let mayLaunch: Bool

    /// 从小程序自己的位置找到它所在的 App：`SkySheet.app/Contents/Helpers/skysheet-mcp`。
    static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> AppConnection {
        let appURL = environment["SKYSHEET_MCP_APP"].map { URL(fileURLWithPath: $0) } ?? enclosingApp()
        let bundle = appURL.flatMap { Bundle(url: $0) }
        let bundleID = bundle?.bundleIdentifier ?? "ai.skylu.skysheet"
        let version = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return AppConnection(
            appURL: appURL,
            bundleIdentifier: bundleID,
            socketPath: environment["SKYSHEET_MCP_SOCKET"] ?? MCPBridge.socketPath(bundleIdentifier: bundleID),
            appVersion: version,
            mayLaunch: environment["SKYSHEET_MCP_NO_LAUNCH"] == nil
        )
    }

    private static func enclosingApp() -> URL? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        var url = executable.deletingLastPathComponent()
        // 最多往上找四层：Helpers → Contents → SkySheet.app。
        for _ in 0..<4 {
            if url.pathExtension == "app" { return url }
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: 一次调用

    func call(tool: String, arguments: JSONValue, client: String?) -> JSONValue {
        let request = MCPBridge.Request(tool: tool, arguments: arguments, client: client)
        do {
            let payload = try JSONEncoder().encode(request)
            let (fd, launched) = try connectOrLaunch()
            defer { close(fd) }
            MCPUnixSocket.setTimeouts(fd, seconds: 120)
            try MCPUnixSocket.writeLine(fd, payload)
            guard let line = try MCPUnixSocket.readLine(fd) else {
                return MCPBridge.textResult(
                    "SkySheet closed the connection without answering (it may have quit). Try again.", isError: true)
            }
            let result = try JSONDecoder().decode(MCPBridge.Response.self, from: line).result
            // 刚把 App 拉起来：之前打开的工作簿都不在了，先说一句，不然 AI 只看到「没有这个 sheet」，要自己去猜。
            return launched ? MCPBridge.addingNote(MCPBridge.relaunchNote, to: result) : result
        } catch let failure as ConnectionFailure {
            return MCPBridge.textResult(failure.message, isError: true)
        } catch {
            return MCPBridge.textResult("Could not talk to SkySheet: \(error)", isError: true)
        }
    }

    private struct ConnectionFailure: Error {
        let message: String
    }

    /// 连上正在跑的 SkySheet；没开就拉起来再连。`launched`：这次是不是拉起来的。
    private func connectOrLaunch() throws -> (fd: Int32, launched: Bool) {
        if let fd = try? MCPUnixSocket.connect(path: socketPath) { return (fd, false) }
        guard mayLaunch else {
            throw ConnectionFailure(message: "SkySheet is not running. Ask the user to open SkySheet.")
        }
        try launchApp()
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
            if let fd = try? MCPUnixSocket.connect(path: socketPath) { return (fd, true) }
        }
        throw ConnectionFailure(message: """
            SkySheet did not start answering within 45 seconds. If an older SkySheet without AI support is open, \
            ask the user to quit it; otherwise ask them to open SkySheet and try again.
            """)
    }

    /// `open -g`：在后台启动，不把用户正在打字的对话窗口挤下去。带上 `--launched-by-ai`：App 就不弹「打开」面板
    /// （没人看着时弹框会把这次调用挂住）。
    private func launchApp() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if let appURL {
            process.arguments = ["-g", "-a", appURL.path, "--args", MCPBridge.launchedByAIArgument]
        } else {
            process.arguments = ["-g", "-b", bundleIdentifier, "--args", MCPBridge.launchedByAIArgument]
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ConnectionFailure(message: "Could not start SkySheet: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ConnectionFailure(message: "Could not start SkySheet (open exited with \(process.terminationStatus)).")
        }
    }
}
