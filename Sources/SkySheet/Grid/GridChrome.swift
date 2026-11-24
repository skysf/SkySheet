import AppKit
import SkyFolioTheme

/// 每次切换外观时给行列标题选一组实色，滚动和局部重画时不用逐格解析动态颜色。
@MainActor
enum GridChrome {
    struct Palette {
        let headerBackground: NSColor
        let cornerBackground: NSColor
        let separator: NSColor
        let selectedText: NSColor
        let text: NSColor
        let selectionTint: NSColor

        @MainActor init(_ variant: KeyPath<FolioTheme.Swatch, NSColor>) {
            headerBackground = FolioTheme.header[keyPath: variant]
            cornerBackground = FolioTheme.peach[keyPath: variant]
            separator = FolioTheme.rule[keyPath: variant]
            selectedText = FolioTheme.ink[keyPath: variant]
            text = FolioTheme.secondaryInk[keyPath: variant]
            selectionTint = FolioTheme.accent[keyPath: variant]
        }
    }

    private static let light = Palette(\.light)
    private static let dark = Palette(\.dark)

    /// 逐条画表头时反复调用动态颜色的外观解析会拖慢滚动；一帧选一次，循环里只设置已有颜色。
    static func palette(for appearance: NSAppearance) -> Palette {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    }

}
