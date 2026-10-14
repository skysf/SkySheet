import AppKit
import SkySheetCore
import SkySheetDisplay

/// Format 菜单（2026-10-14 加，设计第 16 条）：粗体、斜体、数字格式、字的颜色、底色、对齐、自动换行、合并单元格。
/// 改的是选区里的格子（整列整行只到用到的地方）；粗体这类开关看活动格现在是什么样，和 Excel 一样。
extension SpreadsheetView {
    /// 活动格现在的样子：开关类菜单项打勾、点了以后变成相反的，都看它。
    private var activeStyle: ResolvedStyle {
        session.styles.style(session.sheet.cells[session.selection.cursor]?.styleIndex ?? 0)
    }

    @objc func toggleCellBold(_ sender: Any?) {
        session.restyleSelection(.init(bold: !activeStyle.font.bold), actionName: String(localized: "Bold"))
    }

    @objc func toggleCellItalic(_ sender: Any?) {
        session.restyleSelection(.init(italic: !activeStyle.font.italic), actionName: String(localized: "Italic"))
    }

    @objc func toggleWrapText(_ sender: Any?) {
        session.restyleSelection(.init(wrapText: !activeStyle.wrapText), actionName: String(localized: "Wrap Text"))
    }

    /// 菜单项的 representedObject 是 FormatPreset 的名字。
    @objc func applyNumberFormat(_ sender: Any?) {
        guard let name = (sender as? NSMenuItem)?.representedObject as? String, let preset = FormatPreset(rawValue: name) else { return }
        session.restyleSelection(.init(numberFormat: preset.code), actionName: String(localized: "Number Format"))
    }

    /// representedObject 是 ARGB 十六进制，或者 FormatPalette.automatic（回到默认的字色）。
    @objc func applyTextColor(_ sender: Any?) {
        guard let color = paletteColor(sender) else { return }
        session.restyleSelection(.init(fontColor: color), actionName: String(localized: "Text Color"))
    }

    /// representedObject 是 ARGB 十六进制，或者 FormatPalette.automatic（不填）。
    @objc func applyFillColor(_ sender: Any?) {
        guard let color = paletteColor(sender) else { return }
        session.restyleSelection(.init(fillColor: color), actionName: String(localized: "Fill Color"))
    }

    private func paletteColor(_ sender: Any?) -> Workbook.CellStyleChange.Color? {
        guard let value = (sender as? NSMenuItem)?.representedObject as? String else { return nil }
        return value == FormatPalette.automatic ? .automatic : .rgb(value)
    }

    /// representedObject 是 CellStyleChange.Horizontal 的名字。
    @objc func alignHorizontally(_ sender: Any?) {
        guard let name = (sender as? NSMenuItem)?.representedObject as? String,
              let alignment = Workbook.CellStyleChange.Horizontal(rawValue: name) else { return }
        session.restyleSelection(.init(horizontal: alignment), actionName: String(localized: "Alignment"))
    }

    /// representedObject 是 CellStyleChange.Vertical 的名字。
    @objc func alignVertically(_ sender: Any?) {
        guard let name = (sender as? NSMenuItem)?.representedObject as? String,
              let alignment = Workbook.CellStyleChange.Vertical(rawValue: name) else { return }
        session.restyleSelection(.init(vertical: alignment), actionName: String(localized: "Alignment"))
    }

    /// 合并选中的格子。左上角以外有内容的先问（和 Excel 一样，合并只留左上角那一格）。
    @objc func mergeCells(_ sender: Any?) {
        let range = session.selection.range
        let lost = session.workbook.cellsLostByMerging(range, sheet: session.sheetIndex)
        let merge: @MainActor () -> Void = { [session] in
            do {
                try session.mergeSelection()
            } catch {
                NSSound.beep()
            }
        }
        guard !lost.isEmpty else { return merge() }
        LayoutCommands.confirmMerge(keeping: range.start, losing: lost.count, in: window, then: merge)
    }

    @objc func unmergeCells(_ sender: Any?) {
        session.unmergeSelection()
    }

    // MARK: - 菜单的勾和能不能点

    /// 格式这一组菜单项：认得就返回能不能点（顺带打勾），不认得返回 nil。编辑格子的时候都不能点（第一版没有一格里几种字体）。
    func validateFormatItem(_ item: NSMenuItem) -> Bool? {
        let style = activeStyle
        let editable = session.editing == nil && session.formattableRange != nil
        switch item.action {
        case #selector(toggleCellBold(_:)): item.state = style.font.bold ? .on : .off
        case #selector(toggleCellItalic(_:)): item.state = style.font.italic ? .on : .off
        case #selector(toggleWrapText(_:)): item.state = style.wrapText ? .on : .off
        case #selector(applyNumberFormat(_:)):
            let preset = (item.representedObject as? String).flatMap(FormatPreset.init(rawValue:))
            item.state = preset?.code == style.formatCode ? .on : .off
        case #selector(alignHorizontally(_:)):
            item.state = (item.representedObject as? String) == style.horizontal.rawValue ? .on : .off
        case #selector(alignVertically(_:)):
            item.state = (item.representedObject as? String) == style.vertical.rawValue ? .on : .off
        case #selector(applyTextColor(_:)), #selector(applyFillColor(_:)):
            break
        case #selector(mergeCells(_:)):
            let range = session.selection.range
            return session.editing == nil && session.selection.kind == .cells && range.rowCount * range.columnCount > 1
                && !session.sheet.merges.contains(range)
        case #selector(unmergeCells(_:)):
            let range = session.selection.range
            return session.editing == nil && session.sheet.merges.contains { $0.intersection(range) != nil }
        default:
            return nil
        }
        return editable
    }
}

/// Format 菜单里的颜色。和 Excel 的标准色、主题浅色一样，打开后在别的软件里也是这个颜色。
enum FormatPalette {
    /// 「自动」：字回到默认颜色，底色不填。
    static let automatic = "auto"

    static let text: [(name: String, argb: String)] = [
        (String(localized: "Dark Red"), "FFC00000"), (String(localized: "Red"), "FFFF0000"),
        (String(localized: "Orange"), "FFED7D31"), (String(localized: "Green"), "FF00B050"),
        (String(localized: "Blue"), "FF0070C0"), (String(localized: "Purple"), "FF7030A0"),
        (String(localized: "Gray"), "FF7F7F7F"),
    ]

    static let fill: [(name: String, argb: String)] = [
        (String(localized: "Light Yellow"), "FFFFF2CC"), (String(localized: "Light Orange"), "FFFCE4D6"),
        (String(localized: "Light Red"), "FFFFC7CE"), (String(localized: "Light Green"), "FFE2EFDA"),
        (String(localized: "Light Blue"), "FFDDEBF7"), (String(localized: "Light Purple"), "FFE4DFEC"),
        (String(localized: "Light Gray"), "FFF2F2F2"), (String(localized: "Yellow"), "FFFFFF00"),
    ]

    /// 菜单项前面的小色块。
    static func swatch(_ argb: String) -> NSImage {
        let color = RGBAColor(hex: argb).map(NSColor.init) ?? .clear
        return NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2).fill()
            NSColor(white: 0, alpha: 0.25).setStroke()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), xRadius: 2, yRadius: 2).stroke()
            return true
        }
    }
}
