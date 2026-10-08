import Foundation
import SkySheetCore

/// xl/styles.xml：数字格式、字体、填充、边框和 `<cellXfs>`。
///
/// 同名元素出现在好几个地方，按「在谁里面」区分：`<xf>` 只认 `<cellXfs>` 里的（`<cellStyleXfs>` 里也有）；
/// `<font>` `<fill>` `<border>` 只认顶层列表里的（`<dxfs>` 里条件格式用的那些不算）；`<color>` 看它的上一层是字体还是边框。
final class StylesPart: XMLScanHandler {
    private(set) var numberFormats: [Int: String] = [:]
    private(set) var cellFormats: [CellFormat] = []
    private(set) var fonts: [FontStyle] = []
    private(set) var fills: [FillStyle] = []
    private(set) var borders: [BorderStyle] = []

    private var path: [String] = []
    private var font: FontStyle?
    private var fill: FillStyle?
    private var border: BorderStyle?
    private var edge: (side: String, style: String?, color: StyleColor?)?
    private var cellFormat: CellFormat?

    func start(_ element: String, attributes: [String: String]) {
        let parent = path.last
        path.append(element)
        switch (parent, element) {
        case ("numFmts", "numFmt"):
            if let id = attributes["numFmtId"].flatMap({ Int($0) }), let code = attributes["formatCode"] {
                numberFormats[id] = code
            }
        case ("cellXfs", "xf"):
            cellFormat = CellFormat(numberFormatID: int(attributes["numFmtId"]), fontID: int(attributes["fontId"]),
                                    fillID: int(attributes["fillId"]), borderID: int(attributes["borderId"]))
        case ("xf", "alignment") where cellFormat != nil:
            cellFormat?.horizontalAlignment = attributes["horizontal"]
            cellFormat?.verticalAlignment = attributes["vertical"]
            cellFormat?.wrapText = flag(attributes["wrapText"], absent: false)
        case ("fonts", "font"):
            font = FontStyle()
        case ("font", _) where font != nil:
            readFontProperty(element, attributes)
        case ("fills", "fill"):
            fill = FillStyle()
        case ("fill", "patternFill") where fill != nil:
            fill?.pattern = attributes["patternType"]
        case ("patternFill", "fgColor") where fill != nil:
            fill?.foreground = Self.color(attributes)
        case ("patternFill", "bgColor") where fill != nil:
            fill?.background = Self.color(attributes)
        case ("borders", "border"):
            border = BorderStyle()
        case ("border", _) where border != nil && ["left", "right", "top", "bottom", "start", "end"].contains(element):
            edge = (element, attributes["style"], nil)
        case (_, "color") where edge != nil && parent == edge?.side:
            edge?.color = Self.color(attributes)
        default:
            break
        }
    }

    func end(_ element: String, text: String) {
        path.removeLast()
        let parent = path.last
        switch (parent, element) {
        case ("cellXfs", "xf"):
            if let cellFormat { cellFormats.append(cellFormat) }
            cellFormat = nil
        case ("fonts", "font"):
            if let font { fonts.append(font) }
            font = nil
        case ("fills", "fill"):
            if let fill { fills.append(fill) }
            fill = nil
        case ("borders", "border"):
            if let border { borders.append(border) }
            border = nil
        case ("border", _) where edge?.side == element:
            if let edge, let style = edge.style, style != "none" {
                let value = BorderEdge(style: style, color: edge.color)
                switch element {
                case "left", "start": border?.left = value
                case "right", "end": border?.right = value
                case "top": border?.top = value
                default: border?.bottom = value
                }
            }
            edge = nil
        default:
            break
        }
    }

    /// 字体的属性：`<b/>` 就是粗体（val 不写等于 true），`<b val="0"/>` 是明确不粗；`<u/>` 不写 val 是单下划线。
    private func readFontProperty(_ element: String, _ attributes: [String: String]) {
        switch element {
        case "name": font?.name = attributes["val"]
        case "sz": font?.size = attributes["val"].flatMap { Double($0) }
        case "b": font?.bold = flag(attributes["val"], absent: true)
        case "i": font?.italic = flag(attributes["val"], absent: true)
        case "strike": font?.strikethrough = flag(attributes["val"], absent: true)
        case "u": font?.underline = attributes["val"].map { $0 != "none" } ?? true
        case "color": font?.color = Self.color(attributes)
        default: break
        }
    }

    static func color(_ attributes: [String: String]) -> StyleColor? {
        let tint = attributes["tint"].flatMap { Double($0) } ?? 0
        if let rgb = attributes["rgb"] { return StyleColor(.rgb(rgb), tint: tint) }
        if let theme = attributes["theme"].flatMap({ Int($0) }) { return StyleColor(.theme(theme), tint: tint) }
        if let indexed = attributes["indexed"].flatMap({ Int($0) }) { return StyleColor(.indexed(indexed), tint: tint) }
        if flag(attributes["auto"], absent: false) { return StyleColor(.automatic) }
        return nil
    }

    private func int(_ text: String?) -> Int {
        text.flatMap { Int($0) } ?? 0
    }

    private func flag(_ text: String?, absent: Bool) -> Bool {
        Self.flag(text, absent: absent)
    }

    private static func flag(_ text: String?, absent: Bool) -> Bool {
        guard let text else { return absent }
        return ["1", "true"].contains(text.lowercased())
    }
}

/// xl/theme/theme1.xml 里的配色：`<a:clrScheme>` 的 12 种颜色。系统色（sysClr）取它的 lastClr。
final class ThemePart: XMLScanHandler {
    static let slots = ["dk1", "lt1", "dk2", "lt2", "accent1", "accent2", "accent3", "accent4", "accent5",
                        "accent6", "hlink", "folHlink"]

    private var found: [String: String] = [:]
    private var inScheme = false
    private var slot: String?

    /// 12 种都找到才算；缺了就用 Office 的默认配色。
    var colors: [String]? {
        let ordered = Self.slots.compactMap { found[$0] }
        return ordered.count == Self.slots.count ? ordered : nil
    }

    func start(_ element: String, attributes: [String: String]) {
        switch element {
        case "clrScheme": inScheme = true
        case _ where inScheme && Self.slots.contains(element): slot = element
        case "srgbClr" where slot != nil: found[slot!] = attributes["val"]
        case "sysClr" where slot != nil: found[slot!] = attributes["lastClr"]
        default: break
        }
    }

    func end(_ element: String, text: String) {
        if element == slot { slot = nil }
        if element == "clrScheme" { inScheme = false }
    }
}
