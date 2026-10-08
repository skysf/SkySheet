import AppKit
import SkySheetCore
import SkySheetDisplay

/// 画一张 sheet 要用的东西：几何、样式、字体、合并单元格。换 sheet 或者缩放时重建一份。
@MainActor
final class SheetCanvas {
    let sheet: Sheet
    let geometry: SheetGeometry
    let styles: StyleResolver
    let dateSystem: DateSystem
    let fonts = FontBook()
    /// 这一轮 AI 改过的格子：淡紫色高亮（设计 8.3 节）。
    let aiTouched: Set<CellAddress>

    init(session: SheetSession) {
        sheet = session.sheet
        styles = session.styles
        dateSystem = session.workbook.dateSystem
        aiTouched = session.aiTouched[session.sheet.id] ?? []
        geometry = SheetGeometry(sheet: session.sheet, baseFontSize: session.styles.baseFontSize,
                                 digitWidth: fonts.digitWidth(session.styles.style(0).font), zoom: session.zoom)
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
        sheet.merges.first { $0.contains(address) }
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

    /// 默认字体（100% 缩放）里数字的最大宽度：Excel 的列宽单位（SheetGeometry 的说明）。
    /// 不取整：苹方 13.3 点的数字宽 8.16，舍成 8 的话列窄了 2%，「150234.55」就放不下了（2026-10-08 截图）。
    func digitWidth(_ font: ResolvedFont) -> Double {
        let probe = self.font(font, points: font.size * SheetGeometry.pixelsPerPoint)
        let widths = "0123456789".map { (String($0) as NSString).size(withAttributes: [.font: probe]).width }
        return widths.max() ?? 7
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
