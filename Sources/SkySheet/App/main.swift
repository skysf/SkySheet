import AppKit
import SkySheetFiles

// 截图、测速只往新文件里写（NewFile）：命令行给的输出路径已经有东西就拒绝、以 1 退出，绝不覆盖。在建 NSApplication
// 之前查，什么都还没做。真写的时候还会再查一次（同样不覆盖）。
let developerOutputs = (SnapshotRequest(arguments: CommandLine.arguments).map { [$0.output] } ?? [])
    + (BenchmarkRequest(arguments: CommandLine.arguments).map { [$0.keepFile, $0.json].compactMap { $0 } } ?? [])
do {
    try NewFile.ensureAbsent(developerOutputs)
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}

// SkySheet 的入口。不用 SwiftUI 的 App 生命周期：文档层是 AppKit 的 NSDocument（设计 8.1 节），菜单也用代码搭。
let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()
