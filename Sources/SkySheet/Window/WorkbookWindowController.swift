import AppKit
import SwiftUI

/// 一个工作簿一个窗口：上面公式栏、中间表格、下面页签和合计。
@MainActor
final class WorkbookWindowController: NSWindowController {
    init(session: SheetSession) {
        let window = NSWindow(contentViewController: WorkbookViewController(session: session))
        window.setContentSize(NSSize(width: 1100, height: 720))
        window.minSize = NSSize(width: 480, height: 320)
        super.init(window: window)
        shouldCascadeWindows = true
        // 第一次（没记住位置）摆在主屏幕正中：被 AI 在后台拉起来时，默认位置可能落在别的屏幕边上（2026-10-09）。
        if !window.setFrameUsingName("SkySheetWorkbook") { window.center() }
        windowFrameAutosaveName = "SkySheetWorkbook"
        // 记住的大小比最小尺寸还小（以前存坏的）就不用它。
        if window.frame.width < window.minSize.width || window.frame.height < window.minSize.height {
            window.setContentSize(NSSize(width: 1100, height: 720))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

@MainActor
final class WorkbookViewController: NSViewController {
    let session: SheetSession
    private(set) var spreadsheet: SpreadsheetView?

    init(session: SheetSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 720))
        let formulaBar = NSHostingView(rootView: FormulaBar(session: session))
        // AI 在改的时候才有内容；平时高度是 0（设计 8.3 节）。只让内容决定它的高度：默认的 sizingOptions 还会把
        // SwiftUI 内容的最大宽度变成约束，空横幅的最大宽度是 0，整个窗口被拉成 130 点宽（2026-10-09 端到端时抓到的）。
        let banner = NSHostingView(rootView: AIBanner(session: session))
        banner.sizingOptions = [.intrinsicContentSize]
        banner.setContentHuggingPriority(.defaultLow, for: .horizontal)
        banner.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spreadsheet = SpreadsheetView(session: session)
        let bottomBar = NSHostingView(rootView: BottomBar(session: session))
        let topLine = Self.separator()
        let bottomLine = Self.separator()
        for view in [formulaBar, banner, topLine, spreadsheet, bottomLine, bottomBar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            formulaBar.topAnchor.constraint(equalTo: container.topAnchor),
            banner.topAnchor.constraint(equalTo: formulaBar.bottomAnchor),
            topLine.topAnchor.constraint(equalTo: banner.bottomAnchor),
            spreadsheet.topAnchor.constraint(equalTo: topLine.bottomAnchor),
            bottomLine.topAnchor.constraint(equalTo: spreadsheet.bottomAnchor),
            bottomBar.topAnchor.constraint(equalTo: bottomLine.bottomAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            formulaBar.heightAnchor.constraint(equalToConstant: 28),
            bottomBar.heightAnchor.constraint(equalToConstant: 28),
            topLine.heightAnchor.constraint(equalToConstant: 1),
            bottomLine.heightAnchor.constraint(equalToConstant: 1),
        ])
        for view in [formulaBar, banner, topLine, spreadsheet, bottomLine, bottomBar] as [NSView] {
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor).isActive = true
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor).isActive = true
        }
        view = container
        self.spreadsheet = spreadsheet
        session.focusGrid = { [weak spreadsheet] in
            guard let spreadsheet else { return }
            spreadsheet.window?.makeFirstResponder(spreadsheet)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(spreadsheet)
    }

    private static func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        return line
    }
}
