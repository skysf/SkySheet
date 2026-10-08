import Foundation
import Observation
import SkySheetCore
import SkySheetDisplay

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
    /// 文档的撤销管理器，窗口建好时接上。
    @ObservationIgnored weak var undoManager: UndoManager?
    /// 公式栏编辑完把键盘还给表格（窗口建好时接上）。
    @ObservationIgnored var focusGrid: (@MainActor () -> Void)?

    init(workbook: Workbook) {
        self.workbook = workbook
        styles = StyleResolver(workbook: workbook)
        sheetIndex = workbook.sheets.firstIndex { $0.visibility == .visible } ?? 0
        resetSelection()
    }

    var sheet: Sheet { workbook.sheets[sheetIndex] }

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
    func select(_ address: CellAddress, extend: Bool = false) {
        let clamped = CellAddress(row: min(max(address.row, 0), CellAddress.maxRows - 1),
                                  column: min(max(address.column, 0), CellAddress.maxColumns - 1))
        selection = extend ? Selection(anchor: selection.anchor, cursor: clamped) : Selection(at: clamped)
        selection.range = expandedToMerges(CellRange(selection.anchor, selection.cursor))
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
    var anchor: CellAddress
    var cursor: CellAddress
    var range: CellRange

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
