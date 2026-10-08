import Foundation

/// 工作簿的样式表：数字格式、字体、填充、边框，和把它们组合起来的 `cellFormats`（xlsx 的 `<cellXfs>`）。
/// 照文件里的样子存（颜色还是主题色编号、字体可以只写了一部分），怎么换算成屏幕上的颜色和字体是显示层的事。
public struct StyleTable: Hashable, Sendable {
    /// 文件里 `<numFmts>` 自定义的格式：编号 → 格式代码。
    public var customNumberFormats: [Int: String]
    /// `<cellXfs>`：下标就是单元格的样式编号。
    public var cellFormats: [CellFormat]
    public var fonts: [FontStyle]
    public var fills: [FillStyle]
    public var borders: [BorderStyle]

    /// 默认值是新建工作簿的样式表（csv 打开的、没有样式表的 xlsx）：和 Excel 新建的文件一样，一个 Calibri 11 号字，
    /// 填充的前两项 none、gray125 是 Excel 保留的，一个空边框。保存成 xlsx 再读回来，一项一项对得上。
    public init(customNumberFormats: [Int: String] = [:], cellFormats: [CellFormat] = [CellFormat()],
                fonts: [FontStyle] = StyleTable.defaultFonts, fills: [FillStyle] = StyleTable.defaultFills,
                borders: [BorderStyle] = StyleTable.defaultBorders) {
        self.customNumberFormats = customNumberFormats
        self.cellFormats = cellFormats
        self.fonts = fonts
        self.fills = fills
        self.borders = borders
    }

    public static let defaultFonts = [FontStyle(name: "Calibri", size: 11)]
    public static let defaultFills = [FillStyle(pattern: "none"), FillStyle(pattern: "gray125")]
    public static let defaultBorders = [BorderStyle()]

    /// 没写默认行高时 Excel 按默认字体（第 0 个字体）的字号算：11 磅是 15 磅高，10 磅是 13.5 磅高，四舍五入到 0.75 磅。
    /// 显示和保存都用它，存出去再读回来行高不变。
    public var defaultRowHeight: Double {
        Self.rowHeight(forFontSize: fonts.first?.size ?? 11)
    }

    public static func rowHeight(forFontSize size: Double) -> Double {
        max(12.75, (size * 1.36 / 0.75).rounded() * 0.75)
    }

    public func numberFormatID(forStyle index: Int) -> Int {
        cellFormats.indices.contains(index) ? cellFormats[index].numberFormatID : 0
    }

    /// 一个样式的数字格式代码：文件里自定义的优先，其次是内置编号表，都没有就是 General。
    public func formatCode(forStyle index: Int) -> String {
        let id = numberFormatID(forStyle: index)
        return customNumberFormats[id] ?? BuiltinFormats.code(for: id) ?? "General"
    }
}

/// xlsx 里 `<cellXfs>` 的一项。
public struct CellFormat: Hashable, Sendable {
    public var numberFormatID: Int
    public var fontID: Int
    public var fillID: Int
    public var borderID: Int
    /// general、left、center、right、fill、justify、centerContinuous、distributed；nil 等于 general。
    public var horizontalAlignment: String?
    /// top、center、bottom、justify、distributed；nil 等于 bottom（Excel 的默认）。
    public var verticalAlignment: String?
    public var wrapText: Bool

    public init(numberFormatID: Int = 0, fontID: Int = 0, fillID: Int = 0, borderID: Int = 0,
                horizontalAlignment: String? = nil, verticalAlignment: String? = nil, wrapText: Bool = false) {
        self.numberFormatID = numberFormatID
        self.fontID = fontID
        self.fillID = fillID
        self.borderID = borderID
        self.horizontalAlignment = horizontalAlignment
        self.verticalAlignment = verticalAlignment
        self.wrapText = wrapText
    }
}

/// 一个字体。nil 表示文件里没写：腾讯文档写的字体常常只有一部分属性（没有名字、只有粗细），
/// 缺的名字、字号、颜色从第 0 个字体（工作簿的默认字体）继承。
public struct FontStyle: Hashable, Sendable {
    public var name: String?
    /// 磅。
    public var size: Double?
    public var bold: Bool?
    public var italic: Bool?
    public var underline: Bool?
    public var strikethrough: Bool?
    public var color: StyleColor?

    public init(name: String? = nil, size: Double? = nil, bold: Bool? = nil, italic: Bool? = nil,
                underline: Bool? = nil, strikethrough: Bool? = nil, color: StyleColor? = nil) {
        self.name = name
        self.size = size
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strikethrough = strikethrough
        self.color = color
    }
}

/// 一种填充。第一版只画纯色（solid）；别的图案（gray125 之类）按前景色画浅一点。
public struct FillStyle: Hashable, Sendable {
    /// none、solid、gray125、darkGrid……；nil 等于 none。
    public var pattern: String?
    public var foreground: StyleColor?
    public var background: StyleColor?

    public init(pattern: String? = nil, foreground: StyleColor? = nil, background: StyleColor? = nil) {
        self.pattern = pattern
        self.foreground = foreground
        self.background = background
    }
}

public struct BorderStyle: Hashable, Sendable {
    public var left: BorderEdge?
    public var right: BorderEdge?
    public var top: BorderEdge?
    public var bottom: BorderEdge?

    public init(left: BorderEdge? = nil, right: BorderEdge? = nil, top: BorderEdge? = nil, bottom: BorderEdge? = nil) {
        self.left = left
        self.right = right
        self.top = top
        self.bottom = bottom
    }
}

public struct BorderEdge: Hashable, Sendable {
    /// thin、medium、thick、dashed、dotted、double、hair、mediumDashed……
    public var style: String
    public var color: StyleColor?

    public init(style: String, color: StyleColor? = nil) {
        self.style = style
        self.color = color
    }
}

/// 文件里写的颜色：ARGB、主题色编号、老的 64 色调色板编号，或者「自动」。`tint` 是 -1…1 的明暗调整。
public struct StyleColor: Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        /// "FF9E1E1A" 这样的 ARGB 十六进制。
        case rgb(String)
        case theme(Int)
        case indexed(Int)
        case automatic
    }

    public var source: Source
    public var tint: Double

    public init(_ source: Source, tint: Double = 0) {
        self.source = source
        self.tint = tint
    }
}
