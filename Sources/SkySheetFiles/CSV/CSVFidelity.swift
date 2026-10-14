import Foundation
import SkySheetCore

/// csv 只存值：格式、合并单元格、冻结窗格这些都存不下（设计 7.3 节）。2026-10-14 起界面上能改格式了，存 csv 之前要能看出
/// 「这次改了 csv 存不下的东西」，问一句要不要另存成 xlsx，别悄悄丢掉。
extension CSVWriter {
    /// 这张表和打开（或上次保存）时比，有没有改了 csv 存不下的样子：格子的字体、底色、边框、对齐、换行、数字格式，
    /// 合并单元格，藏起来的行列，行高，冻结窗格。日期、百分比 csv 写得出来、读回来还是日期、百分比，不算；列宽也不算
    /// （csv 每次打开都按内容重新定宽）。和上次比而不是看有没有：用户选了「只存数据」以后，下一次 ⌘S 不再问。
    public static func losesFormatting(_ sheet: Sheet, styles: StyleTable, comparedTo baseline: Sheet?,
                                       baselineStyles: StyleTable?) -> Bool {
        let before = baseline.map { Look(of: $0, styles: baselineStyles ?? styles) } ?? Look(of: Sheet(id: 0, name: ""), styles: styles)
        return Look(of: sheet, styles: styles) != before
    }

    /// 一张表上 csv 存不下的那部分样子。
    private struct Look: Equatable {
        var cells: [CellAddress: CellFormat] = [:]
        var hiddenColumns: [ClosedRange<Int>] = []
        var rows: [Int: RowFormat] = [:]
        var merges: Set<CellRange> = []
        var frozen: FrozenPanes?

        init(of sheet: Sheet, styles: StyleTable) {
            sheet.cells.forEach { address, cell in
                guard styles.cellFormats.indices.contains(cell.styleIndex) else { return }
                var format = styles.cellFormats[cell.styleIndex]
                let code = styles.formatCode(forStyle: cell.styleIndex)
                if code == "General" || ValueFormatter.isDateFormat(code) || code.contains("%") { format.numberFormatID = 0 }
                // 同一本里样式表只往后加（设计 7.2 节），打开时和现在的编号指的是同一样东西，直接比。
                if format != CellFormat() { cells[address] = format }
            }
            hiddenColumns = sheet.columns.filter(\.hidden).map { $0.first...$0.last }
            rows = sheet.rowFormats.filter { $0.value.height != nil || $0.value.hidden || $0.value.styleIndex != nil }
            merges = Set(sheet.merges)
            frozen = sheet.frozen.flatMap { $0.rows > 0 || $0.columns > 0 ? $0 : nil }
        }
    }
}
