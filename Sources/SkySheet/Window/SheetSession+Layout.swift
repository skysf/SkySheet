import Foundation
import SkySheetCore
import SkySheetFiles

/// 行和列：宽高、隐藏、冻结、插删（设计第 16 条，2026-10-14 加）。和别的编辑一样都走 `apply`：一步撤销，
/// 直接改到的 AI 的 sheet 记「最后是谁改的」。界面上的菜单、拖边线用这些；AI 的 edit_rows_columns 走 AIContext.change，
/// 改的是同一组 Workbook 上的函数。
extension SheetSession {
    /// 几列的宽度（Excel 的字符数）或几行的高度（磅），每一行（列）可以不一样（自动适应）；nil 是回到默认大小。
    func setSizes(_ sizes: [Int: Double?], _ axis: SheetAxis, actionName: String) {
        guard !sizes.isEmpty else { return }
        let index = sheetIndex
        apply(actionName) { workbook in
            for (line, size) in sizes {
                switch axis {
                case .columns: workbook.setColumnWidth(size, columns: line...line, sheet: index)
                case .rows: workbook.setRowHeight(size, rows: line...line, sheet: index)
                }
            }
        }
    }

    /// 几列（行）设成一样大。
    func setSize(_ size: Double?, _ axis: SheetAxis, lines: ClosedRange<Int>) {
        let index = sheetIndex
        apply(axis == .columns ? String(localized: "Column Width") : String(localized: "Row Height")) { workbook in
            switch axis {
            case .columns: workbook.setColumnWidth(size, columns: lines, sheet: index)
            case .rows: workbook.setRowHeight(size, rows: lines, sheet: index)
            }
        }
    }

    func setHidden(_ hidden: Bool, _ axis: SheetAxis, lines: ClosedRange<Int>) {
        let index = sheetIndex
        let name = switch (hidden, axis) {
        case (true, .columns): String(localized: "Hide Columns")
        case (false, .columns): String(localized: "Unhide Columns")
        case (true, .rows): String(localized: "Hide Rows")
        case (false, .rows): String(localized: "Unhide Rows")
        }
        apply(name) { $0.setHidden(hidden, axis, lines, sheet: index) }
    }

    /// 冻结上面 `rows` 行、左边 `columns` 列；都是 0 就是取消冻结。
    func freeze(rows: Int, columns: Int) {
        let index = sheetIndex
        apply(rows > 0 || columns > 0 ? String(localized: "Freeze Panes") : String(localized: "Unfreeze Panes")) {
            $0.freeze(rows: rows, columns: columns, sheet: index)
        }
    }

    /// 插删行列（先问过 `structureLock`）。改完把这一轮 AI 改过的格子的高亮跟着挪。
    @discardableResult
    func shiftLines(_ shift: LineShift) throws -> StructureEditReport {
        let index = sheetIndex
        let name = switch (shift.kind, shift.axis) {
        case (.insert, .rows): String(localized: "Insert Rows")
        case (.insert, .columns): String(localized: "Insert Columns")
        case (.delete, .rows): String(localized: "Delete Rows")
        case (.delete, .columns): String(localized: "Delete Columns")
        }
        var report = StructureEditReport()
        try apply(name) { report = try $0.shiftLines(shift, sheet: index) }
        remapHighlights(after: shift, sheetID: sheet.id)
        return report
    }

    /// 插删行列以后，这一轮 AI 改过的格子的高亮跟着格子挪（删掉的不要了）。
    func remapHighlights(after shift: LineShift, sheetID: Int) {
        guard let touched = aiTouched[sheetID] else { return }
        aiTouched[sheetID] = Set(touched.compactMap { address in
            shift.map(shift.axis.index(of: address)).map { shift.axis.moving(address, to: $0) }
        })
    }

    /// 这张表为什么不能插删行列；能就是 nil。
    var structureLockOfCurrentSheet: StructureLock? {
        structureLock?(sheet.id)
    }
}

/// 改格子的样子（Format 菜单，设计第 16 条，2026-10-14 加）。
extension SheetSession {
    /// 一次最多改这么多格。整列整行、一大块选区只改用到的那部分。
    static let formatLimit = 200_000

    /// 改格式时真正要改的格子：整列整行只到用到的地方为止；一大块也先截到用到的地方。没有可改的（空表上选了整列）
    /// 或者还是太大，返回 nil。
    var formattableRange: CellRange? {
        guard var range = selectedCells else { return nil }
        if range.rowCount * range.columnCount > Self.formatLimit {
            guard let used = sheet.cells.usedRange,
                  let clamped = range.intersection(CellRange(CellAddress(row: 0, column: 0), used.end)) else { return nil }
            range = clamped
        }
        return range.rowCount * range.columnCount <= Self.formatLimit ? range : nil
    }

    func restyleSelection(_ change: Workbook.CellStyleChange, actionName: String) {
        guard let range = formattableRange else { return }
        let index = sheetIndex
        apply(actionName) { $0.restyle(range, sheet: index, change) }
    }

    /// 合并选中的格子（调用方已经问过用户要不要丢掉左上角以外的内容）。
    func mergeSelection() throws {
        let range = selection.range
        let index = sheetIndex
        try apply(String(localized: "Merge Cells")) { try $0.merge(range, sheet: index, discardingOthers: true) }
        // 选中合并好的那一格：光标在左上角（存东西的那一格），选区包住整块。
        select(range.start)
    }

    func unmergeSelection() {
        let range = selection.range
        let index = sheetIndex
        apply(String(localized: "Unmerge Cells")) { $0.unmerge(range, sheet: index) }
    }
}
