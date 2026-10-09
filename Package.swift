// swift-tools-version: 6.0
import PackageDescription

// SkySheet：给 AI 用的轻量 macOS 表格。模块怎么分、为什么这么分见设计第三节
// （docs/plans/2026-10-08-skysheet-design.md）。
// 零第三方依赖（设计第 7 条）：压缩用系统的 Compression，SQL 查询用系统的 SQLite3。
let package = Package(
    name: "SkySheet",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "SkySheet", targets: ["SkySheet"]),
        // Claude Code 启动的 MCP 小程序，打包时放进 SkySheet.app/Contents/Helpers/（设计第三节、9.1 节）。
        .executable(name: "skysheet-mcp", targets: ["SkySheetMCP"]),
    ],
    targets: [
        // zip 读写：xlsx 本质上是一个 zip 包。
        .target(name: "SkyZip"),
        // 值类型的工作簿模型、公式引擎和函数库、数字格式。不碰任何文件格式。
        .target(name: "SkySheetCore"),
        // xlsx、csv 读写：把文件变成 SkySheetCore 的模型。
        .target(name: "SkySheetFiles", dependencies: ["SkySheetCore", "SkyZip"]),
        // 画表格要做的决定：颜色换算、样式继承、行列几何、格子显示成什么。和 AppKit 无关，自检能测。
        .target(name: "SkySheetDisplay", dependencies: ["SkySheetCore"]),
        // MCP 协议、工具清单（唯一一份）、和 App 之间的通道。小程序和 App 共用，只依赖 Foundation。
        .target(name: "SkySheetMCPKit"),
        // skysheet-mcp：握手和工具清单当场回，工具调用转给 App。
        .executableTarget(name: "SkySheetMCP", dependencies: ["SkySheetMCPKit"]),
        // App：文档、窗口、表格视图（AppKit + SwiftUI）、AI 层。打包见 scripts/build-app.sh。
        .executableTarget(
            name: "SkySheet",
            dependencies: ["SkySheetCore", "SkySheetFiles", "SkySheetDisplay", "SkySheetMCPKit"]
        ),
        // 自检。本机只有命令行工具，没有 XCTest，也没有 Swift Testing（设计第十二节），
        // 所以是一个可执行程序：全过退出码 0。scripts/check-all.sh 调它，CI 也跑同一个。
        .executableTarget(
            name: "SkySheetChecks",
            dependencies: ["SkyZip", "SkySheetCore", "SkySheetFiles", "SkySheetDisplay", "SkySheetMCPKit"]
        ),
    ]
)
