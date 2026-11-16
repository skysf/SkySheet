import AppKit
import SkySheetCore
import SkySheetFiles
import SkySheetDisplay
import SkyZip

// 和截图一样只在后台建立视图；不用文档入口，不读恢复目录、不接系统剪贴板。
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
application.appearance = NSAppearance(named: .aqua)
// 和正式 App 一样在任何文档之前建好，让子类成为 shared（NSDocument 的 init 会先建出一个普通的）。ui-29 用它。
_ = WorkbookDocumentController()
let suites = ["editing", "copy-limit", "theme", "format", "appearance", "locale", "drawing"]
let requested = CommandLine.arguments.dropFirst().first
let selected = requested.map { [$0] } ?? suites
Task { @MainActor in
    for suite in selected {
        switch suite {
        case "editing": sessionEditingChecks(); closeDecisionChecks(); dateSystemPasteChecks(); editingRenameChecks(); benchmarkModeChecks()
        case "copy-cost": sparseClipboardCostChecks()
        case "copy-limit": copyLimitChecks()
        case "theme": invalidThemeChecks()
        case "format": invalidFormatColorChecks()
        case "appearance": chromeContrastChecks()
        case "locale": sizeLocaleChecks()
        case "drawing":
            mergedPaneBorderChecks()
            centeredOverflowChecks()
            await cursorExtentChecks()
            synchronousScrollerChecks()
            canvasShrinkChecks()
        default: fatalError("Unknown UI check suite")
        }
    }
    finishChecks()
}
application.run()
