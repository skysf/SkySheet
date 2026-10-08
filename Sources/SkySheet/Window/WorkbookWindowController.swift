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
        windowFrameAutosaveName = "SkySheetWorkbook"
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
        let spreadsheet = SpreadsheetView(session: session)
        let bottomBar = NSHostingView(rootView: BottomBar(session: session))
        let topLine = Self.separator()
        let bottomLine = Self.separator()
        for view in [formulaBar, topLine, spreadsheet, bottomLine, bottomBar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            formulaBar.topAnchor.constraint(equalTo: container.topAnchor),
            topLine.topAnchor.constraint(equalTo: formulaBar.bottomAnchor),
            spreadsheet.topAnchor.constraint(equalTo: topLine.bottomAnchor),
            bottomLine.topAnchor.constraint(equalTo: spreadsheet.bottomAnchor),
            bottomBar.topAnchor.constraint(equalTo: bottomLine.bottomAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            formulaBar.heightAnchor.constraint(equalToConstant: 28),
            bottomBar.heightAnchor.constraint(equalToConstant: 28),
            topLine.heightAnchor.constraint(equalToConstant: 1),
            bottomLine.heightAnchor.constraint(equalToConstant: 1),
        ])
        for view in [formulaBar, topLine, spreadsheet, bottomLine, bottomBar] as [NSView] {
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
