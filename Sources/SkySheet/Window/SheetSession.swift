import Foundation
import Observation
import SkySheetCore
import SkySheetDisplay
import SkySheetFiles

/// 一个窗口里大家共用的状态：工作簿、看的是哪张 sheet、选中了哪里、缩放、正在编辑的格子。
/// SwiftUI 的公式栏和底栏直接观察它；AppKit 的表格视图用 `observeChanges` 订阅。
/// 改工作簿都走 `apply`（SheetSession+Editing.swift）：改完整本重算，登记撤销。
@MainActor
@Observable
final class SheetSession {
    var workbook: Workbook
    var styles: StyleResolver
    var sheetIndex: Int
    var selection = Selection(at: CellAddress(row: 0, column: 0))
    private(set) var zoom = 1.0
    /// 正在编辑的格子：格内的编辑框和公式栏共用这一份，哪边打字另一边跟着变。
    var editing: CellEditing?
    /// 改了几次（每次 apply、撤销、重做都加一）。恢复副本按它判断要不要重写。
    var revision = 0
    /// 这一轮 AI 改过的格子（sheet 编号 → 格子），淡色高亮；下一轮开始时清掉，不存进文件（设计 8.3 节）。
    var aiTouched: [Int: Set<CellAddress>] = [:]
    /// 正在拖列标、行号的边线：拖的时候只改画出来的样子，松手才改工作簿（一步撤销）。
    var resizePreview: ResizePreview?
    /// 文档的撤销管理器，窗口建好时接上。
    @ObservationIgnored weak var undoManager: UndoManager?
    /// 这张 sheet（按编号）为什么不能插删行列，能就是 nil（设计第 11 条，StructureLock）。文档建窗口时接上；
    /// 没接（截图模式）就是都能。
    @ObservationIgnored var structureLock: (@MainActor (_ sheetID: Int) -> StructureLock?)?
    /// 公式栏编辑完把键盘还给表格（窗口建好时接上）。
    @ObservationIgnored var focusGrid: (@MainActor () -> Void)?

    init(workbook: Workbook) {
        self.workbook = workbook
        styles = StyleResolver(workbook: workbook)
        sheetIndex = workbook.sheets.firstIndex { $0.visibility == .visible } ?? 0
        resetSelection()
    }

    var sheet: Sheet { workbook.sheets[sheetIndex] }

    /// 画出来的那张 sheet：正在拖边线时带着拖到的大小。
    var displayedSheet: Sheet {
        guard let preview = resizePreview else { return sheet }
        var copy = sheet
        switch preview.axis {
        case .columns: copy.setColumnWidth(preview.size, columns: preview.lines)
        case .rows: copy.setRowHeight(preview.size, rows: preview.lines)
        }
        return copy
    }

    /// 页签上显示的 sheet（隐藏的不显示）。
    var tabIndices: [Int] {
        workbook.sheets.indices.filter { workbook.sheets[$0].visibility == .visible }
    }

    func showSheet(_ index: Int) {
        guard workbook.sheets.indices.contains(index), index != sheetIndex else { return }
        // 正在编辑的先提交：提交时按当前看的 sheet 写，换了 sheet 再提交就写错地方了。
        commitEditing()
        sheetIndex = index
        resetSelection()
    }

    /// 选中一格；`extend` 时从原来的起点拉到这一格（按住 Shift）。碰到合并单元格就把整块框进来。
    /// 原来选的是整列（整行），`keepLines` 时接着按整列拉（拖着、Shift 加方向键）；在格子上 Shift 点一下就变回一块格子。
    func select(_ address: CellAddress, extend: Bool = false, keepLines: Bool = true) {
        let clamped = CellAddress(row: min(max(address.row, 0), CellAddress.maxRows - 1),
                                  column: min(max(address.column, 0), CellAddress.maxColumns - 1))
        if extend, keepLines, selection.kind != .cells {
            selection = Selection(lines: selection.kind, anchor: selection.anchor, cursor: clamped)
            return
        }
        selection = extend ? Selection(anchor: selection.anchor, cursor: clamped) : Selection(at: clamped)
        selection.range = expandedToMerges(CellRange(selection.anchor, selection.cursor))
    }

    /// 点列标（行号）选整列（整行）；`extend` 时从原来的起点拉到这一列（按住 Shift、拖着）。活动格放在 `crossIndex`
    /// 那一行（看得见的最上面一行），表格不跳回第一行。
    func selectLines(_ axis: SheetAxis, through index: Int, extend: Bool, crossIndex: Int) {
        let kind: Selection.Kind = axis == .columns ? .columns : .rows
        let start = axis == .columns ? CellAddress(row: crossIndex, column: index) : CellAddress(row: index, column: crossIndex)
        guard extend else {
            selection = Selection(lines: kind, anchor: start, cursor: start)
            return
        }
        let cursor = axis.moving(selection.kind == kind ? selection.cursor : selection.anchor, to: index)
        selection = Selection(lines: kind, anchor: selection.anchor, cursor: cursor)
    }

    /// 选中一块：整列（C:E）、整行（3:5）按点列标行号那样选；别的从左上角拉到右下角。和 Shift 拉的一样，活动格在拉到的那一头。
    func select(_ range: CellRange) {
        if range.coversAllRows, !range.coversAllColumns {
            selectLines(.columns, through: range.start.column, extend: false, crossIndex: 0)
            selectLines(.columns, through: range.end.column, extend: true, crossIndex: 0)
        } else if range.coversAllColumns, !range.coversAllRows {
            selectLines(.rows, through: range.start.row, extend: false, crossIndex: 0)
            selectLines(.rows, through: range.end.row, extend: true, crossIndex: 0)
        } else {
            select(range.start)
            select(range.end, extend: true)
        }
    }

    /// 选区里真正要处理的格子（复制、改格式）：整列整行只算到表里用到的地方为止，整列有一百多万格。
    /// 整列整行而表是空的，返回 nil。
    var selectedCells: CellRange? {
        guard selection.kind != .cells else { return selection.range }
        guard let used = sheet.cells.usedRange else { return nil }
        return selection.range.intersection(CellRange(CellAddress(row: 0, column: 0), used.end))
    }

    func selectAll() {
        guard let used = sheet.cells.usedRange else { return }
        selection = Selection(anchor: CellAddress(row: 0, column: 0), cursor: used.end)
        selection.range = CellRange(CellAddress(row: 0, column: 0), used.end)
    }

    func setZoom(_ value: Double) {
        zoom = min(max(value, 0.5), 3)
    }

    func resetSelection() {
        // 冻结窗格的话，从第一个不冻结的格子开始，和 Excel 打开时一样。
        let start = CellAddress(row: sheet.frozen?.rows ?? 0, column: sheet.frozen?.columns ?? 0)
        selection = Selection(at: start)
        selection.range = expandedToMerges(selection.range)
    }

    /// 区域碰到的合并单元格整块包进来（一直包到不再变大为止）。
    func expandedToMerges(_ range: CellRange) -> CellRange {
        var result = range
        var changed = true
        while changed {
            changed = false
            for merge in sheet.merges where merge.intersection(result) != nil {
                let grown = CellRange(CellAddress(row: min(result.start.row, merge.start.row),
                                                  column: min(result.start.column, merge.start.column)),
                                      CellAddress(row: max(result.end.row, merge.end.row),
                                                  column: max(result.end.column, merge.end.column)))
                if grown != result {
                    result = grown
                    changed = true
                }
            }
        }
        return result
    }
}

/// 选区：起点（按 Shift 拉的时候不动的那一角）和光标（活动格）。`range` 是包上合并单元格以后的整块。
struct Selection: Equatable {
    /// 选的是一块格子，还是点列标、行号选的整列、整行（`range` 铺满另一个方向）。
    enum Kind: Equatable {
        case cells, columns, rows
    }

    var anchor: CellAddress
    var cursor: CellAddress
    var range: CellRange
    var kind = Kind.cells

    init(at address: CellAddress) {
        anchor = address
        cursor = address
        range = CellRange(address)
    }

    init(anchor: CellAddress, cursor: CellAddress) {
        self.anchor = anchor
        self.cursor = cursor
        range = CellRange(anchor, cursor)
    }

    /// 整列（整行）：从起点那一列拉到光标那一列。
    init(lines kind: Kind, anchor: CellAddress, cursor: CellAddress) {
        self.anchor = anchor
        self.cursor = cursor
        self.kind = kind
        switch kind {
        case .columns: range = .columns(min(anchor.column, cursor.column)...max(anchor.column, cursor.column))
        case .rows: range = .rows(min(anchor.row, cursor.row)...max(anchor.row, cursor.row))
        case .cells: range = CellRange(anchor, cursor)
        }
    }

    /// 选中的那几列、那几行（一块格子就是它占的列、行）。
    var columns: ClosedRange<Int> { range.start.column...range.end.column }
    var rows: ClosedRange<Int> { range.start.row...range.end.row }

    func lines(_ axis: SheetAxis) -> ClosedRange<Int> { axis == .columns ? columns : rows }

    /// 选的是这个方向上的整列（整行）。
    func isWhole(_ axis: SheetAxis) -> Bool { kind == (axis == .columns ? .columns : .rows) }
}

/// 拖边线时预览的大小：哪几列（行）、拖到多大（列是 Excel 的字符数，行是磅）。
struct ResizePreview: Equatable {
    var axis: SheetAxis
    var lines: ClosedRange<Int>
    var size: Double
}

/// 让 AppKit 视图订阅 @Observable 的变化：`read` 里读到的属性一变就调 `onChange`，然后自动重新订阅。
/// 持有者（视图）没了就停，不会一直挂着。
@MainActor
func observeChanges<Owner: AnyObject & Sendable>(_ owner: Owner, read: @escaping @MainActor (Owner) -> Void,
                                         onChange: @escaping @MainActor (Owner) -> Void) {
    withObservationTracking {
        read(owner)
    } onChange: { [weak owner] in
        Task { @MainActor in
            guard let owner else { return }
            onChange(owner)
            observeChanges(owner, read: read, onChange: onChange)
        }
    }
}
