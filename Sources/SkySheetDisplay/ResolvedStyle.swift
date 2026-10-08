import Foundation
import SkySheetCore

/// 一个样式编号最后在屏幕上是什么样：字体、颜色、填充、边框、对齐、数字格式代码。打开文件时一次算好（设计 8.2 节）。
public struct ResolvedStyle: Hashable, Sendable {
    public var font: ResolvedFont
    /// nil 表示不填（透出网格线）。
    public var fill: RGBAColor?
    public var left: ResolvedEdge?
    public var right: ResolvedEdge?
    public var top: ResolvedEdge?
    public var bottom: ResolvedEdge?
    public var horizontal: HorizontalAlignment
    public var vertical: VerticalAlignment
    public var wrapText: Bool
    public var formatCode: String
}

public struct ResolvedFont: Hashable, Sendable {
    /// 文件里写的字体名（Windows 上的，如「等线」）。换成 Mac 上的字体见 `FontMapping`。
    public var name: String
    /// 磅。
    public var size: Double
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var strikethrough: Bool
    public var color: RGBAColor
}

public enum HorizontalAlignment: String, Sendable {
    case general, left, center, right, fill, justify, centerContinuous, distributed
}

public enum VerticalAlignment: String, Sendable {
    case top, center, bottom, justify, distributed
}

/// 一条边框。宽度是 100% 缩放时的点数。
public struct ResolvedEdge: Hashable, Sendable {
    public enum Pattern: Sendable {
        case solid, dashed, dotted, double
    }

    public var width: Double
    public var pattern: Pattern
    public var color: RGBAColor
}

/// 工作簿的每个样式编号对应的 `ResolvedStyle`，打开时一次算好，画的时候直接取。
public struct StyleResolver: Sendable {
    private let styles: [ResolvedStyle]

    public init(workbook: Workbook) {
        let colors = ColorResolver(themeColors: workbook.themeColors)
        let table = workbook.styles
        let base = table.fonts.first ?? FontStyle()
        let baseFont = ResolvedFont(name: base.name ?? "Calibri", size: base.size ?? 11, bold: base.bold ?? false,
                                    italic: base.italic ?? false, underline: base.underline ?? false,
                                    strikethrough: base.strikethrough ?? false,
                                    color: colors.resolve(base.color, fallback: .black) ?? .black)
        let formats = table.cellFormats.isEmpty ? [CellFormat()] : table.cellFormats
        styles = formats.indices.map { index in
            Self.resolve(formats[index], formatCode: table.formatCode(forStyle: index), table: table,
                         baseFont: baseFont, colors: colors)
        }
    }

    public func style(_ index: Int) -> ResolvedStyle {
        styles.indices.contains(index) ? styles[index] : styles[0]
    }

    /// 默认字体的字号（磅）：默认行高按它算。
    public var baseFontSize: Double { styles[0].font.size }

    private static func resolve(_ format: CellFormat, formatCode: String, table: StyleTable, baseFont: ResolvedFont,
                                colors: ColorResolver) -> ResolvedStyle {
        // 只写了一部分的字体（腾讯文档常这样）：缺的名字、字号、颜色从默认字体继承；粗斜体没写就是不粗不斜。
        var font = baseFont
        if table.fonts.indices.contains(format.fontID) {
            let own = table.fonts[format.fontID]
            font = ResolvedFont(name: own.name ?? baseFont.name, size: own.size ?? baseFont.size, bold: own.bold ?? false,
                                italic: own.italic ?? false, underline: own.underline ?? false,
                                strikethrough: own.strikethrough ?? false,
                                color: colors.resolve(own.color, fallback: baseFont.color) ?? baseFont.color)
        }
        let fill = table.fills.indices.contains(format.fillID) ? resolveFill(table.fills[format.fillID], colors) : nil
        let border = table.borders.indices.contains(format.borderID) ? table.borders[format.borderID] : BorderStyle()
        func edge(_ edge: BorderEdge?) -> ResolvedEdge? {
            edge.flatMap { resolveEdge($0, colors) }
        }
        return ResolvedStyle(
            font: font, fill: fill, left: edge(border.left), right: edge(border.right), top: edge(border.top),
            bottom: edge(border.bottom),
            horizontal: format.horizontalAlignment.flatMap(HorizontalAlignment.init(rawValue:)) ?? .general,
            vertical: format.verticalAlignment.flatMap(VerticalAlignment.init(rawValue:)) ?? .bottom,
            wrapText: format.wrapText, formatCode: formatCode)
    }

    /// 纯色填充用前景色；别的图案（gray125 之类）没法一点点画，按图案的浓淡把前景色调浅。
    private static func resolveFill(_ fill: FillStyle, _ colors: ColorResolver) -> RGBAColor? {
        guard let pattern = fill.pattern, pattern != "none" else { return nil }
        guard let color = colors.resolve(fill.foreground, fallback: .black) else { return nil }
        let density: [String: Double] = ["solid": 1, "gray0625": 0.0625, "gray125": 0.125, "lightGray": 0.25,
                                         "mediumGray": 0.5, "darkGray": 0.75]
        let amount = density[pattern] ?? 0.5
        return amount == 1 ? color : color.blended(withWhite: amount)
    }

    private static func resolveEdge(_ edge: BorderEdge, _ colors: ColorResolver) -> ResolvedEdge? {
        let color = colors.resolve(edge.color, fallback: .black) ?? .black
        switch edge.style {
        case "hair": return ResolvedEdge(width: 0.5, pattern: .solid, color: color)
        case "thin": return ResolvedEdge(width: 1, pattern: .solid, color: color)
        case "medium": return ResolvedEdge(width: 2, pattern: .solid, color: color)
        case "thick": return ResolvedEdge(width: 3, pattern: .solid, color: color)
        case "double": return ResolvedEdge(width: 3, pattern: .double, color: color)
        case "dotted": return ResolvedEdge(width: 1, pattern: .dotted, color: color)
        case "dashed", "dashDot", "dashDotDot", "slantDashDot":
            return ResolvedEdge(width: 1, pattern: .dashed, color: color)
        case "mediumDashed", "mediumDashDot", "mediumDashDotDot":
            return ResolvedEdge(width: 2, pattern: .dashed, color: color)
        default: return nil
        }
    }
}

/// Windows 上常见的字体 → Mac 上有的字体，按顺序试，都没有就用系统字体。
public enum FontMapping {
    public static func candidates(for name: String) -> [String] {
        let mapped: [String: [String]] = [
            "等线": ["DengXian", "PingFang SC"], "等线 Light": ["DengXian Light", "PingFang SC"],
            "DengXian": ["DengXian", "PingFang SC"], "微软雅黑": ["Microsoft YaHei", "PingFang SC"],
            "Microsoft YaHei": ["Microsoft YaHei", "PingFang SC"], "宋体": ["SimSun", "Songti SC"],
            "SimSun": ["SimSun", "Songti SC"], "新宋体": ["NSimSun", "Songti SC"], "黑体": ["SimHei", "Heiti SC"],
            "SimHei": ["SimHei", "Heiti SC"], "楷体": ["KaiTi", "Kaiti SC"], "仿宋": ["FangSong", "STFangsong"],
            "Calibri": ["Calibri", "Helvetica Neue"], "Cambria": ["Cambria", "Georgia"],
            "Arial": ["Arial", "Helvetica"], "Tahoma": ["Tahoma", "Verdana"],
        ]
        return mapped[name] ?? [name]
    }
}
