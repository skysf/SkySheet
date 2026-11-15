import AppKit

/// 截图模式、测速模式用的窗口：建好、排好版，但**从不放上屏幕**（不 orderFront），画都画进位图。
/// `defer: true`：窗口在系统那边根本不建出来，系统也就不会自己来画它（不 defer 的话，没放上屏幕的窗口系统照样画，
/// 测速时同一块要画两遍，2026-11-14 实测）。
/// 作者开着别的东西干活时也能跑（2026-11-14 定的规矩）：不弹窗、不抢焦点、不在 Dock 里出现。
/// 从命令行直接跑的 SkySheet 不在 App 包里，系统默认就是 `.prohibited`（不进 Dock、不能被激活，2026-11-14 实测）；
/// 从 App 包里跑时也一样，启动时就设成 `.prohibited`（AppDelegate）。
@MainActor
enum OffscreenWindow {
    static func make(_ controller: NSViewController, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered,
                              defer: true)
        window.contentViewController = controller
        window.setContentSize(size)
        return window
    }

    /// 让 SwiftUI、自动布局和 observeChanges 的回调跑完（窗口不在屏幕上，系统不会自己来画，只是把该算的算完）。
    static func settle(_ window: NSWindow, for seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        window.layoutIfNeeded()
    }

    /// 把整个窗口内容画成一张位图（每个视图都完整重画一遍）。
    static func render(_ window: NSWindow) -> NSBitmapImageRep? {
        guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }
}
