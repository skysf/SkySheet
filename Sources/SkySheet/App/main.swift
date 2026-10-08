import AppKit

// SkySheet 的入口。不用 SwiftUI 的 App 生命周期：文档层是 AppKit 的 NSDocument（设计 8.1 节），菜单也用代码搭。
let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()
