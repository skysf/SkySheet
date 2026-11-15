import AppKit
import SkySheetCore
import SkySheetFiles
import SkySheetDisplay
import SkyZip
@testable import SkySheet

// 和截图一样只在后台建立视图；不用文档入口，不读恢复目录、不接系统剪贴板。
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
application.appearance = NSAppearance(named: .aqua)
let suite = CommandLine.arguments.dropFirst().first ?? "editing"
Task { @MainActor in
    switch suite {
    case "editing": sessionEditingChecks()
    case "copy-limit": copyLimitChecks()
    case "theme": invalidThemeChecks()
    case "format": invalidFormatColorChecks()
    case "locale": sizeLocaleChecks()
    default: fatalError("Unknown UI check suite")
    }
    finishChecks()
}
application.run()
