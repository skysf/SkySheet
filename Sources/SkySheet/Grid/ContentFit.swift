import AppKit
import SkySheetCore
import SkySheetDisplay

/// 按内容定列宽、行高时量文字（2026-10-14 加）：规矩在 SkySheetDisplay 的 AutoFit，量字要用真正画的字体，所以在 App 这一层。
/// 双击边线、菜单、AI 的 edit_rows_columns autofit 都用它。藏起来的行列不动。
@MainActor
enum ContentFit {
    /// 第 `index` 张表每一列按内容的宽度（Excel 的字符数）；nil 是那一列没有内容，回到默认宽度。
    static func widths(_ columns: ClosedRange<Int>, sheet index: Int, in session: SheetSession,
                       fonts: FontBook) -> [Int: Double?] {
        let sheet = session.workbook.sheets[index]
        let digit = fonts.digitWidth(session.styles.style(0).font)
        var result: [Int: Double?] = [:]
        for column in visible(columns, .columns, in: sheet) {
            result[column] = AutoFit.width(ofColumn: column, in: sheet, styles: session.styles,
                                           dateSystem: session.workbook.dateSystem, digitWidth: digit,
                                           measure: { fonts.width(of: $0, style: $1) })
        }
        return result
    }

    /// 第 `index` 张表每一行按内容的高度（磅）；nil 是回到默认行高。自动换行的格子按现在的列宽折行。
    static func heights(_ rows: ClosedRange<Int>, sheet index: Int, in session: SheetSession,
                        fonts: FontBook) -> [Int: Double?] {
        let sheet = session.workbook.sheets[index]
        let geometry = SheetGeometry(sheet: sheet, baseFontSize: session.styles.baseFontSize,
                                     digitWidth: fonts.digitWidth(session.styles.style(0).font))
        let defaultHeight = sheet.defaultRowHeight ?? StyleTable.rowHeight(forFontSize: session.styles.baseFontSize)
        var result: [Int: Double?] = [:]
        for row in visible(rows, .rows, in: sheet) {
            result[row] = AutoFit.height(ofRow: row, in: sheet, styles: session.styles, dateSystem: session.workbook.dateSystem,
                                         defaultHeight: defaultHeight, columnWidth: { geometry.columnWidth($0) },
                                         lineCount: { lineCount($0, style: $1, width: $2, fonts: fonts) })
        }
        return result
    }

    /// 一段文字在这么宽里折成几行（100% 缩放的屏幕点）。
    private static func lineCount(_ text: String, style: ResolvedStyle, width: Double, fonts: FontBook) -> Int {
        let font = fonts.font(style.font, points: style.font.size * SheetGeometry.pixelsPerPoint)
        let bounding = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                       options: [.usesLineFragmentOrigin], attributes: [.font: font])
        let line = NSLayoutManager().defaultLineHeight(for: font)
        return max(1, Int((bounding.height / max(line, 1)).rounded()))
    }

    /// 只量看得见的：藏起来的行列保持原样。整列选中时行数是一百多万，只看用到的那些行。
    private static func visible(_ lines: ClosedRange<Int>, _ axis: SheetAxis, in sheet: Sheet) -> [Int] {
        var span = lines
        if let used = sheet.cells.usedRange {
            let last = axis == .rows ? used.end.row : used.end.column
            if span.upperBound > last { span = span.lowerBound...max(span.lowerBound, last) }
        }
        return span.filter { !sheet.isHidden(axis, $0) }
    }
}
