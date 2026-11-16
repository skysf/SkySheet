import AppKit

/// 表格内容固定白底和文件颜色；界面灰底则要和动态的 labelColor 成对，不能在 Dark Aqua 上白字配浅灰底。
@MainActor
enum GridChrome {
    struct Palette {
        let headerBackground: NSColor
        let cornerBackground: NSColor
        let separator: NSColor
        let headerSeparator: NSColor
        let selectedText: NSColor

        init(header: CGFloat, corner: CGFloat, separator: CGFloat, headerSeparator: CGFloat, selectedText: NSColor) {
            headerBackground = NSColor(white: header, alpha: 1)
            cornerBackground = NSColor(white: corner, alpha: 1)
            self.separator = NSColor(white: separator, alpha: 1)
            self.headerSeparator = NSColor(white: headerSeparator, alpha: 1)
            self.selectedText = selectedText
        }
    }

    private static let light = Palette(header: 0.965, corner: 0.93, separator: 0.78, headerSeparator: 0.82,
                                       selectedText: .controlAccentColor)
    private static let dark = Palette(header: 0.16, corner: 0.20, separator: 0.38, headerSeparator: 0.32,
                                      selectedText: .white)

    /// 逐条画表头时反复调用动态颜色的外观解析会拖慢滚动；一帧选一次，循环里只设置已有颜色。
    static func palette(for appearance: NSAppearance) -> Palette {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    }

    static let sizeBackground = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(white: dark ? 0.16 : 1, alpha: 0.95)
    }

}
