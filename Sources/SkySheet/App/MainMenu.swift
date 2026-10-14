import AppKit
import SkySheetCore

/// 菜单栏用代码搭（没有 nib）。界面只用英文（设计第 22 条），文字都走 String(localized:)，以后加中文只是补翻译。
/// 表格的命令（编辑、插删行列、格式、冻结）都发给第一响应者，也就是表格视图；标题和打勾在它的 validateMenuItem 里现算。
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        let appName = "SkySheet"
        main.addItem(submenu(appName, [
            item(String(localized: "About \(appName)"), #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item(String(localized: "Settings…"), #selector(AppDelegate.showSettings(_:)), key: ","),
            .separator(),
            item(String(localized: "Hide \(appName)"), #selector(NSApplication.hide(_:)), key: "h"),
            item(String(localized: "Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), key: "h",
                 modifiers: [.command, .option]),
            item(String(localized: "Show All"), #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item(String(localized: "Quit \(appName)"), #selector(NSApplication.terminate(_:)), key: "q"),
        ]))
        main.addItem(submenu(String(localized: "File"), [
            item(String(localized: "Open…"), #selector(NSDocumentController.openDocument(_:)), key: "o"),
            .separator(),
            item(String(localized: "Close"), #selector(NSWindow.performClose(_:)), key: "w"),
            item(String(localized: "Save"), #selector(NSDocument.save(_:)), key: "s"),
            item(String(localized: "Save As…"), #selector(NSDocument.saveAs(_:)), key: "s", modifiers: [.command, .shift]),
            item(String(localized: "Revert to Saved"), #selector(NSDocument.revertToSaved(_:))),
        ]))
        main.addItem(submenu(String(localized: "Edit"), [
            item(String(localized: "Undo"), #selector(SpreadsheetView.undo(_:)), key: "z"),
            item(String(localized: "Redo"), #selector(SpreadsheetView.redo(_:)), key: "z", modifiers: [.command, .shift]),
            .separator(),
            item(String(localized: "Cut"), #selector(SpreadsheetView.cut(_:)), key: "x"),
            item(String(localized: "Copy"), #selector(SpreadsheetView.copy(_:)), key: "c"),
            item(String(localized: "Paste"), #selector(SpreadsheetView.paste(_:)), key: "v"),
            item(String(localized: "Delete"), #selector(SpreadsheetView.delete(_:))),
            item(String(localized: "Select All"), #selector(NSResponder.selectAll(_:)), key: "a"),
            .separator(),
            // 标题按选区现算：「Delete Rows 3–5」。
            item(String(localized: "Delete Rows"), #selector(SpreadsheetView.deleteRows(_:))),
            item(String(localized: "Delete Columns"), #selector(SpreadsheetView.deleteColumns(_:))),
        ]))
        main.addItem(submenu(String(localized: "Insert"), [
            item(String(localized: "Insert Rows Above"), #selector(SpreadsheetView.insertRowsAbove(_:))),
            item(String(localized: "Insert Rows Below"), #selector(SpreadsheetView.insertRowsBelow(_:))),
            .separator(),
            item(String(localized: "Insert Columns Left"), #selector(SpreadsheetView.insertColumnsLeft(_:))),
            item(String(localized: "Insert Columns Right"), #selector(SpreadsheetView.insertColumnsRight(_:))),
        ]))
        main.addItem(submenu(String(localized: "Format"), formatItems()))
        main.addItem(submenu(String(localized: "Sheet"), [
            item(String(localized: "Rename Sheet…"), #selector(SpreadsheetView.renameSheet(_:))),
            item(String(localized: "Duplicate Sheet"), #selector(SpreadsheetView.duplicateSheet(_:))),
            .separator(),
            item(String(localized: "Delete Sheet"), #selector(SpreadsheetView.deleteSheet(_:))),
        ]))
        main.addItem(submenu(String(localized: "View"), [
            item(String(localized: "Freeze Top Row"), #selector(SpreadsheetView.freezeTopRow(_:))),
            item(String(localized: "Freeze First Column"), #selector(SpreadsheetView.freezeFirstColumn(_:))),
            item(String(localized: "Freeze Panes"), #selector(SpreadsheetView.freezePanes(_:))),
            item(String(localized: "Unfreeze Panes"), #selector(SpreadsheetView.unfreezePanes(_:))),
            .separator(),
            item(String(localized: "Actual Size"), #selector(SpreadsheetView.resetZoom(_:)), key: "0"),
            item(String(localized: "Zoom In"), #selector(SpreadsheetView.zoomIn(_:)), key: "+"),
            item(String(localized: "Zoom Out"), #selector(SpreadsheetView.zoomOut(_:)), key: "-"),
        ]))
        let windowMenu = submenu(String(localized: "Window"), [
            item(String(localized: "Minimize"), #selector(NSWindow.performMiniaturize(_:)), key: "m"),
            item(String(localized: "Zoom"), #selector(NSWindow.performZoom(_:))),
            .separator(),
            item(String(localized: "Bring All to Front"), #selector(NSApplication.arrangeInFront(_:))),
        ])
        main.addItem(windowMenu)
        NSApp.windowsMenu = windowMenu.submenu
        return main
    }

    /// Format 菜单（2026-10-14 加）：格子的样子，加上列、行的宽高和隐藏。
    private static func formatItems() -> [NSMenuItem] {
        let numberFormats: [NSMenuItem] = [
            item(String(localized: "General"), #selector(SpreadsheetView.applyNumberFormat(_:)), value: FormatPreset.general.rawValue),
            item(String(localized: "Number (1,234.56)"), #selector(SpreadsheetView.applyNumberFormat(_:)),
                 value: FormatPreset.number.rawValue),
            item(String(localized: "Percent (12.34%)"), #selector(SpreadsheetView.applyNumberFormat(_:)),
                 value: FormatPreset.percent.rawValue),
            .separator(),
            item(String(localized: "Yuan (¥1,234.56)"), #selector(SpreadsheetView.applyNumberFormat(_:)), value: FormatPreset.cny.rawValue),
            item(String(localized: "Yuan, Whole (¥1,235)"), #selector(SpreadsheetView.applyNumberFormat(_:)),
                 value: FormatPreset.cnyInteger.rawValue),
            item(String(localized: "In 10,000s (48.9万)"), #selector(SpreadsheetView.applyNumberFormat(_:)),
                 value: FormatPreset.wan.rawValue),
            item(String(localized: "In 10,000s, Exact (48.9000万)"), #selector(SpreadsheetView.applyNumberFormat(_:)),
                 value: FormatPreset.wanExact.rawValue),
            .separator(),
            item(String(localized: "Date (2025/12/1)"), #selector(SpreadsheetView.applyNumberFormat(_:)), value: FormatPreset.date.rawValue),
            item(String(localized: "Chinese Date (2025年12月1日)"), #selector(SpreadsheetView.applyNumberFormat(_:)),
                 value: FormatPreset.dateChinese.rawValue),
        ]
        let textColors = [item(String(localized: "Automatic"), #selector(SpreadsheetView.applyTextColor(_:)),
                               value: FormatPalette.automatic), .separator()]
            + FormatPalette.text.map { swatch($0.name, $0.argb, #selector(SpreadsheetView.applyTextColor(_:))) }
        let fillColors = [item(String(localized: "No Fill"), #selector(SpreadsheetView.applyFillColor(_:)),
                               value: FormatPalette.automatic), .separator()]
            + FormatPalette.fill.map { swatch($0.name, $0.argb, #selector(SpreadsheetView.applyFillColor(_:))) }
        let alignment: [NSMenuItem] = [
            item(String(localized: "Default"), #selector(SpreadsheetView.alignHorizontally(_:)), value: "general"),
            item(String(localized: "Left"), #selector(SpreadsheetView.alignHorizontally(_:)), value: "left"),
            item(String(localized: "Center"), #selector(SpreadsheetView.alignHorizontally(_:)), value: "center"),
            item(String(localized: "Right"), #selector(SpreadsheetView.alignHorizontally(_:)), value: "right"),
            .separator(),
            item(String(localized: "Top"), #selector(SpreadsheetView.alignVertically(_:)), value: "top"),
            item(String(localized: "Middle"), #selector(SpreadsheetView.alignVertically(_:)), value: "center"),
            item(String(localized: "Bottom"), #selector(SpreadsheetView.alignVertically(_:)), value: "bottom"),
        ]
        return [
            item(String(localized: "Bold"), #selector(SpreadsheetView.toggleCellBold(_:)), key: "b"),
            item(String(localized: "Italic"), #selector(SpreadsheetView.toggleCellItalic(_:)), key: "i"),
            .separator(),
            submenu(String(localized: "Number Format"), numberFormats),
            submenu(String(localized: "Text Color"), textColors),
            submenu(String(localized: "Fill Color"), fillColors),
            .separator(),
            submenu(String(localized: "Alignment"), alignment),
            item(String(localized: "Wrap Text"), #selector(SpreadsheetView.toggleWrapText(_:))),
            .separator(),
            item(String(localized: "Merge Cells"), #selector(SpreadsheetView.mergeCells(_:))),
            item(String(localized: "Unmerge Cells"), #selector(SpreadsheetView.unmergeCells(_:))),
            .separator(),
            submenu(String(localized: "Column"), [
                item(String(localized: "Width…"), #selector(SpreadsheetView.setColumnWidth(_:))),
                item(String(localized: "AutoFit Width"), #selector(SpreadsheetView.autoFitColumns(_:))),
                .separator(),
                item(String(localized: "Hide"), #selector(SpreadsheetView.hideColumns(_:))),
                item(String(localized: "Unhide"), #selector(SpreadsheetView.unhideColumns(_:))),
            ]),
            submenu(String(localized: "Row"), [
                item(String(localized: "Height…"), #selector(SpreadsheetView.setRowHeight(_:))),
                item(String(localized: "AutoFit Height"), #selector(SpreadsheetView.autoFitRows(_:))),
                .separator(),
                item(String(localized: "Hide"), #selector(SpreadsheetView.hideRows(_:))),
                item(String(localized: "Unhide"), #selector(SpreadsheetView.unhideRows(_:))),
            ]),
        ]
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    private static func item(_ title: String, _ action: Selector, key: String = "",
                             modifiers: NSEvent.ModifierFlags = .command, value: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.representedObject = value
        return item
    }

    /// 颜色菜单项：前面一个小色块。
    private static func swatch(_ title: String, _ argb: String, _ action: Selector) -> NSMenuItem {
        let menuItem = item(title, action, value: argb)
        menuItem.image = FormatPalette.swatch(argb)
        return menuItem
    }
}
