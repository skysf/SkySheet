// swift-tools-version: 6.0
import PackageDescription

// SkySheet：给 AI 用的轻量 macOS 表格。模块怎么分、为什么这么分见设计第三节
// （docs/plans/2026-10-08-skysheet-design.md）。
// 零第三方依赖（设计第 7 条）：压缩用系统的 Compression，以后的 SQL 查询用系统的 SQLite3。
let package = Package(
    name: "SkySheet",
    platforms: [.macOS(.v15)],
    targets: [
        // zip 读写：xlsx 本质上是一个 zip 包。
        .target(name: "SkyZip"),
        // 值类型的工作簿模型、公式引擎和函数库、数字格式。不碰任何文件格式。
        .target(name: "SkySheetCore"),
        // xlsx（M2 起还有 csv）读写：把文件变成 SkySheetCore 的模型。
        .target(name: "SkySheetFiles", dependencies: ["SkySheetCore", "SkyZip"]),
        // 自检。本机只有命令行工具，没有 XCTest，也没有 Swift Testing（设计第十二节），
        // 所以是一个可执行程序：全过退出码 0。scripts/check-all.sh 调它，CI 也跑同一个。
        .executableTarget(
            name: "SkySheetChecks",
            dependencies: ["SkyZip", "SkySheetCore", "SkySheetFiles"]
        ),
    ]
)
