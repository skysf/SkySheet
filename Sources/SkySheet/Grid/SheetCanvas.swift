import AppKit
import SkySheetCore
import SkySheetDisplay

/// 画一张 sheet 要用的东西：几何、样式、字体、合并单元格。换 sheet、改了工作簿、缩放、拖边线时重建一份。
///
/// 重建很频繁（拖边线时每动一下都重建），所以和上一份比：格子没变就接着用上一份数出来的用到范围，合并单元格没变就
/// 接着用上一份的查找表，行列大小的设置没变就接着用上一份排好的那个方向（2026-11-14，设计 8.2 节「性能」）。
/// 没改过的东西和上一份是同一份存储，`==` 当场就有结果。
@MainActor
final class SheetCanvas {
    let sheet: Sheet
    let geometry: SheetGeometry
    let styles: StyleResolver
    let dateSystem: DateSystem
    let fonts: FontBook
    /// 默认字体里数字的最大宽度（100% 缩放）：Excel 列宽的单位，拖边线时换算用。
    let digitWidth: Double
    /// 这一轮 AI 改过的格子：淡紫色高亮（设计 8.3 节）。
    let aiTouched: Set<CellAddress>
    /// 合并单元格的查找表：画的时候每格都要问一次（MergeIndex 的说明）。
    let mergeIndex: MergeIndex
    /// 画字用的属性，按（样式编号、颜色、对齐）缓存；缩放一变就是一份新的画布，跟着重建。
    private var textAttributes: [TextStyleKey: TextAttributes] = [:]
    /// 画过的格子显示成什么（DisplayContentCache）：同一张表、样式表和日期系统没变，就接着用上一份画布的。
    let contents: DisplayContentCache

    /// `fonts` 由表格视图带着，重建画布时接着用：拖边线时每动一下都要重建。`previous` 是上一份画布。
    init(session: SheetSession, fonts: FontBook, previous: SheetCanvas? = nil) {
        let sheet = session.displayedSheet
        let digitWidth = fonts.digitWidth(session.styles.style(0).font)
        let styles = session.styles
        let dateSystem = session.workbook.dateSystem
        self.fonts = fonts
        self.sheet = sheet
        self.digitWidth = digitWidth
        self.styles = styles
        self.dateSystem = dateSystem
        aiTouched = session.aiTouched[session.sheet.id] ?? []
        let reusable = previous?.sheet.id == sheet.id ? previous : nil
        // 用到的范围：格子没变就接着用；改过几行（编辑以后）只看改过的行（SparseGrid.usedRange(previous:of:changedRows:)）。
        // 改过的行很多（公式多的表重算以后每个公式格子都是新值）就从头数：逐行比内容反而更贵。
        let usedRange: CellRange?
        if let reusable, reusable.sheet.cells == sheet.cells {
            usedRange = reusable.geometry.usedRange
        } else if let reusable, let rows = sheet.cells.rowsDiffering(from: reusable.sheet.cells, limit: 256) {
            usedRange = sheet.cells.usedRange(previous: reusable.geometry.usedRange, of: reusable.sheet.cells, changedRows: rows)
        } else {
            usedRange = sheet.cells.usedRange
        }
        geometry = SheetGeometry(sheet: sheet, baseFontSize: session.styles.baseFontSize, digitWidth: digitWidth,
                                 zoom: session.zoom, usedRange: usedRange, reusing: reusable?.geometry)
        mergeIndex = if let reusable, reusable.sheet.merges == sheet.merges { reusable.mergeIndex }
                     else { MergeIndex(sheet.merges) }
        contents = if let reusable, reusable.styles == styles, reusable.dateSystem == dateSystem { reusable.contents }
                   else { DisplayContentCache() }
    }

    var frozenRows: Int { min(sheet.frozen?.rows ?? 0, geometry.rowCount) }
    var frozenColumns: Int { min(sheet.frozen?.columns ?? 0, geometry.columnCount) }
    var frozenWidth: CGFloat { geometry.x(ofColumn: frozenColumns) }
    var frozenHeight: CGFloat { geometry.y(ofRow: frozenRows) }

    /// 一块区域在 sheet 坐标里的矩形（左上角是 A1 的左上角，单位是屏幕点）。
    func rect(of range: CellRange) -> CGRect {
        let x = geometry.x(ofColumn: range.start.column)
        let y = geometry.y(ofRow: range.start.row)
        return CGRect(x: x, y: y, width: geometry.x(ofColumn: range.end.column + 1) - x,
                      height: geometry.y(ofRow: range.end.row + 1) - y)
    }

    func merge(containing address: CellAddress) -> CellRange? {
        mergeIndex.merge(containing: address)
    }

    /// 和 `clip`（sheet 坐标）有重叠的合并单元格，按 sheet 里原来的顺序。
    func merges(intersecting clip: CGRect) -> [CellRange] {
        guard !mergeIndex.isEmpty else { return [] }
        var result: [CellRange] = []
        let rows = geometry.row(atY: clip.minY)...geometry.row(atY: clip.maxY)
        for merge in mergeIndex.merges(touchingRows: rows) where rect(of: merge).intersects(clip) {
            result.append(merge)
        }
        return result
    }

    /// 文字溢出时，旁边的格子算不算空：没有值、也不在合并单元格里。
    func isEmpty(row: Int, column: Int) -> Bool {
        let address = CellAddress(row: row, column: column)
        if let cell = sheet.cells[address], cell.value != .empty { return false }
        return merge(containing: address) == nil
    }

    func content(of cell: Cell) -> (DisplayContent, ResolvedStyle) {
        let style = styles.style(cell.styleIndex)
        return (CellDisplay.content(of: cell, style: style, dateSystem: dateSystem), style)
    }

    /// 和 `content(of:)` 一样，画的时候用：按位置记着（DisplayContentCache），没变的格子不再重新排字。
    func content(of cell: Cell, at address: CellAddress) -> (DisplayContent, ResolvedStyle) {
        let style = styles.style(cell.styleIndex)
        return (contents.content(of: cell, at: address, style: style, dateSystem: dateSystem), style)
    }

    /// 这一格的字用什么属性画（字体按当前缩放）。
    func textAttributes(_ cell: Cell, style: ResolvedStyle, content: DisplayContent) -> TextAttributes {
        let key = TextStyleKey(styleIndex: cell.styleIndex, color: content.color, placement: content.placement)
        if let cached = textAttributes[key] { return cached }
        let attributes = TextAttributes(font: fonts.font(style.font, points: geometry.fontPoints(style.font.size)),
                                        color: content.color, placement: content.placement,
                                        underline: style.font.underline, strikethrough: style.font.strikethrough)
        textAttributes[key] = attributes
        return attributes
    }
}

private struct TextStyleKey: Hashable {
    let styleIndex: Int
    let color: RGBAColor
    let placement: HorizontalPlacement
}

/// 一种文字样式画字要的属性，做成一个真正的 NSDictionary 留着用。
///
/// 原来每画一格字都现建一个 Swift 字典（还要新建一个段落样式），交给 AppKit 量字、画字时，AppKit 每查一个键都要把
/// Swift 字典桥接一遍：2026-11-14 实测这一项占了画一帧的三成。现在每种样式只建一次；字串和属性直接拼成
/// CFAttributedString（不经过 Swift 字典），量和画都用它。属性和原来一模一样：字体、颜色、段落样式（对齐、按词换行），
/// 有下划线、删除线的加上。
///
/// 量出来的宽高、数字放不下时显示成什么（CellDisplay.fitNumber）也按文字记在这里：同一种样式、同一个缩放，同一段文字
/// 量出来总是一样（整块重画时，量字、缩数字曾经占了画字的两成，2026-11-14）。条数有上限，满了清空重来。
/// 文字按标量做键（ExactText，2026-11-15）：按 String 做键时 é 和 e + U+0301 共用一条，Verdana、Georgia 这类字体里
/// 两种写法宽度不同，后量的那一格就拿了前一格的宽度，靠右、居中的字画歪（截图复现）。
final class TextAttributes {
    private let dictionary: CFDictionary
    private var sizes: [ExactText: CGSize] = [:]
    private var fitted: [FitKey: String] = [:]
    private static let limit = 20_000

    /// 「常规」格式放不下时按数的全精度缩短：显示文字一样的两个数可能缩出来不一样，所以数也算进去。
    private struct FitKey: Hashable {
        let text: ExactText
        let number: Decimal?
        let general: Bool
        let width: Double
    }

    init(font: NSFont, color: RGBAColor, placement: HorizontalPlacement, underline: Bool, strikethrough: Bool) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = switch placement {
        case .left: .left
        case .center: .center
        case .right: .right
        }
        paragraph.lineBreakMode = .byWordWrapping
        let attributes = NSMutableDictionary()
        attributes[NSAttributedString.Key.font.rawValue] = font
        attributes[NSAttributedString.Key.foregroundColor.rawValue] = NSColor(color)
        attributes[NSAttributedString.Key.paragraphStyle.rawValue] = paragraph
        if underline { attributes[NSAttributedString.Key.underlineStyle.rawValue] = NSUnderlineStyle.single.rawValue }
        if strikethrough { attributes[NSAttributedString.Key.strikethroughStyle.rawValue] = NSUnderlineStyle.single.rawValue }
        dictionary = attributes.copy() as! NSDictionary
    }

    /// 一段文字带上这些属性。
    func line(_ text: String) -> NSAttributedString {
        CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, dictionary) as NSAttributedString
    }

    /// 这段文字画出来多大（`line(text).size()`，记着）。
    func size(of text: String) -> CGSize {
        let key = ExactText(text)
        if let known = sizes[key] { return known }
        let size = line(text).size()
        if sizes.count >= Self.limit { sizes.removeAll(keepingCapacity: true) }
        sizes[key] = size
        return size
    }

    /// 数字在 `width` 这么宽里显示成什么（CellDisplay.fitNumber，记着：结果只由显示文字、数、是不是「常规」和宽度定）。
    func fit(_ content: DisplayContent, width: Double) -> String {
        let key = FitKey(text: ExactText(content.text), number: content.number, general: content.isGeneralNumber, width: width)
        if let known = fitted[key] { return known }
        let text = CellDisplay.fitNumber(content, width: width, measure: { self.size(of: $0).width })
        if fitted.count >= Self.limit { fitted.removeAll(keepingCapacity: true) }
        fitted[key] = text
        return text
    }
}

/// 字体缓存。文件里的字体名多半是 Windows 上的（「等线」「宋体」），按 FontMapping 换成 Mac 上有的，都没有就用系统字体。
@MainActor
final class FontBook {
    private struct Key: Hashable {
        let name: String
        let size: CGFloat
        let bold: Bool
        let italic: Bool
    }

    private var cache: [Key: NSFont] = [:]
    /// 每种默认字体量出来的数字宽度：重建画布时不用再量十个数字。
    private var digitWidths: [ResolvedFont: Double] = [:]

    /// 默认字体（100% 缩放）里数字的最大宽度：Excel 的列宽单位（SheetGeometry 的说明）。
    /// 不取整：苹方 13.3 点的数字宽 8.16，舍成 8 的话列窄了 2%，「150234.55」就放不下了（2026-10-08 截图）。
    func digitWidth(_ font: ResolvedFont) -> Double {
        if let known = digitWidths[font] { return known }
        let probe = self.font(font, points: font.size * SheetGeometry.pixelsPerPoint)
        let widths = "0123456789".map { (String($0) as NSString).size(withAttributes: [.font: probe]).width }
        let width = widths.max() ?? 7
        digitWidths[font] = width
        return width
    }

    /// 一段文字按这个样式（100% 缩放）画出来多宽。
    func width(of text: String, style: ResolvedStyle) -> Double {
        let font = self.font(style.font, points: style.font.size * SheetGeometry.pixelsPerPoint)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    func font(_ font: ResolvedFont, points: CGFloat) -> NSFont {
        let key = Key(name: font.name, size: points, bold: font.bold, italic: font.italic)
        if let cached = cache[key] { return cached }
        var result = FontMapping.candidates(for: font.name).lazy.compactMap { NSFont(name: $0, size: points) }.first
            ?? NSFont.systemFont(ofSize: points)
        let manager = NSFontManager.shared
        if font.bold { result = manager.convert(result, toHaveTrait: .boldFontMask) }
        if font.italic { result = manager.convert(result, toHaveTrait: .italicFontMask) }
        cache[key] = result
        return result
    }
}

extension NSColor {
    convenience init(_ color: RGBAColor) {
        self.init(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}
