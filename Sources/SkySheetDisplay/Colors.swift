import Foundation
import SkySheetCore

/// 屏幕上的颜色，各分量 0…1。和 AppKit 无关，App 自己换成 NSColor。
public struct RGBAColor: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// "RRGGBB" 或 "AARRGGBB"。xlsx 里的透明度一律不管（Excel 也不管），都当不透明。
    public init?(hex: String) {
        let digits = hex.count == 8 ? String(hex.dropFirst(2)) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }

    public static let black = RGBAColor(red: 0, green: 0, blue: 0)
    public static let white = RGBAColor(red: 1, green: 1, blue: 1)

    /// 和白色按比例混合：`amount` 是自己占的比例。画非纯色的图案填充用。
    func blended(withWhite amount: Double) -> RGBAColor {
        RGBAColor(red: red * amount + (1 - amount), green: green * amount + (1 - amount),
                  blue: blue * amount + (1 - amount))
    }
}

/// 把文件里写的颜色换成屏幕上的颜色（设计 8.2 节）。
public struct ColorResolver: Sendable {
    private let theme: [RGBAColor]

    public init(themeColors: [String]) {
        theme = themeColors.compactMap(RGBAColor.init(hex:))
    }

    /// `automatic` 和没写的都用 `fallback`（字体是黑，填充是不填）。
    public func resolve(_ color: StyleColor?, fallback: RGBAColor?) -> RGBAColor? {
        guard let color else { return fallback }
        let base: RGBAColor?
        switch color.source {
        case .rgb(let hex): base = RGBAColor(hex: hex)
        case .theme(let index): base = themeColor(index)
        case .indexed(let index): base = Self.indexedColor(index) ?? fallback
        case .automatic: base = fallback
        }
        guard let base else { return fallback }
        return color.tint == 0 ? base : Self.applyTint(base, color.tint)
    }

    /// 主题色编号的坑：样式里的 0、1、2、3 指的是 lt1、dk1、lt2、dk2，和主题文件里 dk1、lt1、dk2、lt2 的顺序两两对调。
    /// 不对调的话，腾讯文档默认字体的 `theme="1"` 会变成白色，整张表的字都看不见。
    func themeColor(_ index: Int) -> RGBAColor? {
        let slot = index < 4 ? [1, 0, 3, 2][index] : index
        return theme.indices.contains(slot) ? theme[slot] : nil
    }

    /// Excel 的明暗调整：转成 HSL，tint < 0 时亮度乘 (1 + tint)，tint > 0 时亮度往 1 拉 tint 那么多。
    static func applyTint(_ color: RGBAColor, _ tint: Double) -> RGBAColor {
        var (hue, saturation, lightness) = hsl(color)
        lightness = tint < 0 ? lightness * (1 + tint) : lightness * (1 - tint) + tint
        return rgb(hue: hue, saturation: saturation, lightness: min(max(lightness, 0), 1))
    }

    /// 数字格式里的颜色（[Red]、[Color10]）。
    public static func formatColor(_ color: FormatColor) -> RGBAColor? {
        switch color {
        case .named(let name):
            let named = ["Black": "000000", "Blue": "0000FF", "Cyan": "00FFFF", "Green": "00FF00",
                         "Magenta": "FF00FF", "Red": "FF0000", "White": "FFFFFF", "Yellow": "FFFF00"]
            return named[name].flatMap(RGBAColor.init(hex:))
        case .indexed(let number):
            return indexedColor(number + 7)   // [Color1] 是调色板的第 8 个
        }
    }

    /// 老的 64 色调色板（`indexed="…"`）。64 是系统前景色，65 是系统背景色。
    static func indexedColor(_ index: Int) -> RGBAColor? {
        switch index {
        case 64: return .black
        case 65: return .white
        default: return palette.indices.contains(index) ? RGBAColor(hex: palette[index]) : nil
        }
    }

    private static let palette = [
        "000000", "FFFFFF", "FF0000", "00FF00", "0000FF", "FFFF00", "FF00FF", "00FFFF",
        "000000", "FFFFFF", "FF0000", "00FF00", "0000FF", "FFFF00", "FF00FF", "00FFFF",
        "800000", "008000", "000080", "808000", "800080", "008080", "C0C0C0", "808080",
        "9999FF", "993366", "FFFFCC", "CCFFFF", "660066", "FF8080", "0066CC", "CCCCFF",
        "000080", "FF00FF", "FFFF00", "00FFFF", "800080", "800000", "008080", "0000FF",
        "00CCFF", "CCFFFF", "CCFFCC", "FFFF99", "99CCFF", "FF99CC", "CC99FF", "FFCC99",
        "3366FF", "33CCCC", "99CC00", "FFCC00", "FF9900", "FF6600", "666699", "969696",
        "003366", "339966", "003300", "333300", "993300", "993366", "333399", "333333",
    ]

    private static func hsl(_ color: RGBAColor) -> (Double, Double, Double) {
        let high = max(color.red, color.green, color.blue)
        let low = min(color.red, color.green, color.blue)
        let lightness = (high + low) / 2
        guard high != low else { return (0, 0, lightness) }
        let delta = high - low
        let saturation = lightness > 0.5 ? delta / (2 - high - low) : delta / (high + low)
        var hue: Double
        switch high {
        case color.red: hue = (color.green - color.blue) / delta + (color.green < color.blue ? 6 : 0)
        case color.green: hue = (color.blue - color.red) / delta + 2
        default: hue = (color.red - color.green) / delta + 4
        }
        hue /= 6
        return (hue, saturation, lightness)
    }

    private static func rgb(hue: Double, saturation: Double, lightness: Double) -> RGBAColor {
        guard saturation > 0 else { return RGBAColor(red: lightness, green: lightness, blue: lightness) }
        let q = lightness < 0.5 ? lightness * (1 + saturation) : lightness + saturation - lightness * saturation
        let p = 2 * lightness - q
        func channel(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return RGBAColor(red: channel(hue + 1.0 / 3), green: channel(hue), blue: channel(hue - 1.0 / 3))
    }
}
