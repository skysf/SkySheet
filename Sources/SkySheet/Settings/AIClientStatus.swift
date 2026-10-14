import Foundation

/// 设置里每个 AI 客户端那一行的状态（ClaudeCodeSetup、ClaudeDesktopSetup 共用；设计 9.5 节）。
enum AIClientStatus: Equatable {
    case notInstalled
    case notConnected
    case connected
    /// Claude Code：连着这一份，但工具还没放行，每个工具都会问一次。再点「连接」补上。
    case connectedAsking
    /// 连着的是另一份 SkySheet（App 挪过位置，或者装过测试版）。
    case connectedElsewhere
    /// Claude 桌面版：这次运行里改了它的配置，它还没退出过（它只在启动时读；开着时还可能把改的盖掉）。
    /// `connecting`：改的是连上还是断开。
    case restartNeeded(connecting: Bool)
}

/// 包里的那个小程序：AI 客户端启动的就是它。`swift run` 直接跑的开发版里没有它。
enum AIHelper {
    static var url: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/skysheet-mcp")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
}
