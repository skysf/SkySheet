import Foundation
import SkySheetCore

/// csv 没有列宽：打开时按每列最长的显示文字定宽（设计 7.3 节）。不然日期这类比默认列宽长的内容全显示成 ###，
/// 文字也被旁边的格子截断（Excel 打开 csv 就是这样，体验很差）。
public enum AutoFit {
    /// 要加宽的列（Excel 的列宽单位，含边距）。比默认列窄的不动，最宽 60 个字符；只看前 `sampleRows` 行，大文件也快。
    /// `measure` 量一段文字按这个样式画出来有多宽（100% 缩放的屏幕点），`digitWidth` 同 SheetGeometry。
    public static func columns(for sheet: Sheet, styles: StyleResolver, dateSystem: DateSystem, digitWidth: Double,
                               measure: (String, ResolvedStyle) -> Double, sampleRows: Int = 2000) -> [ColumnFormat] {
        var widest: [Int: Double] = [:]
        for row in sheet.cells.rowIndices.prefix(sampleRows) {
            for (column, cell) in sheet.cells.row(row) {
                let style = styles.style(cell.styleIndex)
                let text = CellDisplay.content(of: cell, style: style, dateSystem: dateSystem).text
                guard !text.isEmpty else { continue }
                widest[column] = max(widest[column] ?? 0, measure(text, style))
            }
        }
        let digit = max(digitWidth, 1)
        // 默认列是 8.43 个字符加 5 像素边距；文字宽度加上同样的 5 像素边距（左右各 2、网格线 1）再换算成字符数。
        let defaultWidth = 8.43 + 5 / digit
        return widest.keys.sorted().compactMap { column in
            let characters = min(60, ((widest[column]! + 5) / digit * 100).rounded(.up) / 100)
            return characters > defaultWidth ? ColumnFormat(first: column, last: column, width: characters) : nil
        }
    }
}
