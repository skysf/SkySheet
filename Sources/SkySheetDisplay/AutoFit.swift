import Foundation
import SkySheetCore

/// 按内容定列宽、行高。两处用：
/// - csv 没有列宽：打开时按每列最长的显示文字定宽（设计 7.3 节）。不然日期这类比默认列宽长的内容全显示成 ###，
///   文字也被旁边的格子截断（Excel 打开 csv 就是这样，体验很差）。
/// - 2026-10-14 起的「自动列宽 / 自动行高」：双击列标行号的边线、菜单、AI 的 edit_rows_columns autofit。
///
/// 量文字要用真正画的字体，所以量的办法由 App 传进来（`measure` 量一段文字按这个样式画出来有多宽，100% 缩放的屏幕点）；
/// 这里只管规矩，自检能测。`digitWidth` 同 SheetGeometry。
public enum AutoFit {
    /// csv 打开时要加宽的列（Excel 的列宽单位，含边距）。比默认列窄的不动，最宽 60 个字符；只看前 `sampleRows` 行，大文件也快。
    public static func columns(for sheet: Sheet, styles: StyleResolver, dateSystem: DateSystem, digitWidth: Double,
                               measure: (String, ResolvedStyle) -> Double, sampleRows: Int = 2000) -> [ColumnFormat] {
        let widest = widestText(in: sheet, columns: nil, rows: sheet.cells.rowIndices.prefix(sampleRows), styles: styles,
                                dateSystem: dateSystem, measure: measure)
        let digit = max(digitWidth, 1)
        // 默认列是 8.43 个字符加 5 像素边距；文字宽度加上同样的 5 像素边距（左右各 2、网格线 1）再换算成字符数。
        let defaultWidth = 8.43 + 5 / digit
        return widest.keys.sorted().compactMap { column in
            let characters = min(60, self.characters(widest[column]!, digitWidth: digit))
            return characters > defaultWidth ? ColumnFormat(first: column, last: column, width: characters) : nil
        }
    }

    /// 一列按最宽的内容定宽（Excel 的字符数），比原来窄也照样缩，最宽 255 个字符（Excel 的上限）。整列没有内容返回 nil：
    /// 回到默认列宽。合并单元格不算（Excel 也不算）。
    public static func width(ofColumn column: Int, in sheet: Sheet, styles: StyleResolver, dateSystem: DateSystem,
                             digitWidth: Double, measure: (String, ResolvedStyle) -> Double) -> Double? {
        let widest = widestText(in: sheet, columns: [column], rows: sheet.cells.rowIndices, styles: styles,
                                dateSystem: dateSystem, measure: measure)
        return widest[column].map { min(255, characters($0, digitWidth: max(digitWidth, 1))) }
    }

    /// 一行按最高的内容定高（磅）：每一格要的是「几行字 × 这个字号一行的高度」，一行的高度和默认行高同一个规矩
    /// （StyleTable.rowHeight），默认字号的一行字正好是默认行高。自动换行的格子按列宽折行：`lineCount` 量这段文字在
    /// 这么宽（屏幕点，100% 缩放）里折成几行；`columnWidth` 是那一列有多宽（屏幕点，100% 缩放）。
    /// 和 `defaultHeight` 一样、或者整行没有内容，返回 nil：回到默认行高。最高 409 磅（Excel 的上限）。合并单元格不算。
    public static func height(ofRow row: Int, in sheet: Sheet, styles: StyleResolver, dateSystem: DateSystem,
                              defaultHeight: Double, columnWidth: (Int) -> Double,
                              lineCount: (String, ResolvedStyle, Double) -> Int) -> Double? {
        var tallest: Double?
        for (column, cell) in sheet.cells.row(row) where !isMerged(CellAddress(row: row, column: column), in: sheet) {
            let style = styles.style(cell.styleIndex)
            let content = CellDisplay.content(of: cell, style: style, dateSystem: dateSystem)
            guard content.kind != .empty, !content.text.isEmpty else { continue }
            var lines = content.text.split(separator: "\n", omittingEmptySubsequences: false).count
            if style.wrapText, content.kind == .text {
                lines = max(lines, lineCount(content.text, style, max(columnWidth(column) - 2 * padding, 1)))
            }
            let needed = Double(lines) * StyleTable.rowHeight(forFontSize: style.font.size)
            tallest = max(tallest ?? 0, needed)
        }
        guard let tallest else { return nil }
        let height = min(409, tallest)
        return abs(height - defaultHeight) < 0.001 ? nil : height
    }

    /// 格子里文字左右各留的边距（屏幕点，100% 缩放；RegionRenderer 也是这么画的）。
    public static let padding = 2.0

    /// 每列最宽的一段显示文字（屏幕点）。`columns` 为 nil 是所有列。一格里有换行的按最长的那一行算；
    /// 跨几列的合并单元格不算。
    private static func widestText(in sheet: Sheet, columns: Set<Int>?, rows: some Sequence<Int>, styles: StyleResolver,
                                   dateSystem: DateSystem, measure: (String, ResolvedStyle) -> Double) -> [Int: Double] {
        var widest: [Int: Double] = [:]
        let spanning = sheet.merges.filter { $0.columnCount > 1 }
        for row in rows {
            let cells: [(column: Int, value: Cell)] = columns.map { wanted in
                wanted.sorted().compactMap { column in sheet.cells[row, column].map { (column, $0) } }
            } ?? sheet.cells.row(row)
            for (column, cell) in cells {
                guard !spanning.contains(where: { $0.contains(CellAddress(row: row, column: column)) }) else { continue }
                let style = styles.style(cell.styleIndex)
                let text = CellDisplay.content(of: cell, style: style, dateSystem: dateSystem).text
                guard !text.isEmpty else { continue }
                let width = text.split(separator: "\n").map { measure(String($0), style) }.max() ?? 0
                widest[column] = max(widest[column] ?? 0, width)
            }
        }
        return widest
    }

    /// 文字宽度（屏幕点）加上 5 像素的边距和网格线，换成 Excel 的字符数，往上取到 0.01。
    private static func characters(_ width: Double, digitWidth: Double) -> Double {
        ((width + 5) / digitWidth * 100).rounded(.up) / 100
    }

    private static func isMerged(_ address: CellAddress, in sheet: Sheet) -> Bool {
        sheet.merges.contains { $0.rowCount > 1 && $0.contains(address) }
    }
}
