import AppKit
import SkySheetCore
import SkySheetDisplay

/// 表格的一块窗格。四块用同一个类（设计 8.2 节）：
/// - corner：冻结的行 × 冻结的列，不动；
/// - frozenRows：冻结的行，左右跟着主区滚；
/// - frozenColumns：冻结的列，上下跟着主区滚；
/// - main：其余部分，NSScrollView 的文档视图，自己滚。
/// 鼠标、滚轮事件不在这里处理：顺着响应链交给上面的 SpreadsheetView 统一算是哪一格。
@MainActor
class PaneView: NSView {
    enum Role {
        case corner, frozenRows, frozenColumns, main
    }

    let role: Role
    weak var spreadsheet: SpreadsheetView?

    /// 这块视图的 (0, 0) 对应 sheet 坐标里的哪一点。主区是文档视图，自己会滚，这个值不变。
    var origin: CGPoint = .zero {
        didSet { if origin != oldValue { needsDisplay = true } }
    }

    init(role: Role) {
        self.role = role
        super.init(frame: .zero)
        // macOS 14 起视图默认不裁剪到自己的边界，传进 draw 的脏区域也可能比边界大：不打开的话，
        // 一块窗格刷的白底会盖到别的窗格和公式栏上（2026-10-08 截图里主区整个是白的，就是冻结列那块刷的）。
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let spreadsheet, let canvas = spreadsheet.canvas, let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        let dirtyRect = dirtyRect.intersection(self.bounds)
        guard !dirtyRect.isEmpty else { return }
        let bounds = spreadsheet.cellRanges(for: role)
        let sheetRect = dirtyRect.offsetBy(dx: origin.x, dy: origin.y)
        let geometry = canvas.geometry
        let rows = max(bounds.rows.lowerBound, geometry.row(atY: sheetRect.minY))
            ..< min(bounds.rows.upperBound, geometry.row(atY: sheetRect.maxY) + 1)
        let columns = max(bounds.columns.lowerBound, geometry.column(atX: sheetRect.minX))
            ..< min(bounds.columns.upperBound, geometry.column(atX: sheetRect.maxX) + 1)

        context.saveGState()
        context.translateBy(x: -origin.x, y: -origin.y)
        RegionRenderer(canvas: canvas, rows: rows.isEmpty ? 0..<0 : rows, columns: columns.isEmpty ? 0..<0 : columns,
                       paneColumns: bounds.columns, clip: sheetRect)
            .draw(selection: spreadsheet.session.selection)
        context.restoreGState()

        // 冻结线：冻结区靠滚动区的那一边画深一点的线，和 Excel 一样。
        NSColor(white: 0.62, alpha: 1).setFill()
        if role == .corner || role == .frozenColumns {
            CGRect(x: self.bounds.maxX - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
        }
        if role == .corner || role == .frozenRows {
            CGRect(x: dirtyRect.minX, y: self.bounds.maxY - 1, width: dirtyRect.width, height: 1).fill()
        }
    }
}

/// 主区：不参与「响应式滚动」。不然系统在另一个线程上挪主区的图层，行号列标和冻结窗格在主线程上跟着重画，
/// 快速滚动时会差一帧、看起来在抖。关掉以后滚动和重画在同一次里完成。
@MainActor
final class MainPaneView: PaneView {
    override class var isCompatibleWithResponsiveScrolling: Bool { false }
}

/// 列标（A、B、C…）或行号（1、2、3…）。冻结的部分不动，其余跟着主区滚。选中的那几行 / 几列加深显示。
@MainActor
final class HeaderView: NSView {
    enum Axis {
        case columns, rows
    }

    let axis: Axis
    weak var spreadsheet: SpreadsheetView?

    /// 主区滚了多远（这个方向上）。
    var scroll: CGFloat = 0 {
        didSet { if scroll != oldValue { needsDisplay = true } }
    }

    init(axis: Axis) {
        self.axis = axis
        super.init(frame: .zero)
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.965, alpha: 1).setFill()
        bounds.fill()
        guard let spreadsheet, let canvas = spreadsheet.canvas else { return }
        let geometry = canvas.geometry
        let isColumns = axis == .columns
        let frozen = isColumns ? canvas.frozenColumns : canvas.frozenRows
        let frozenExtent = isColumns ? canvas.frozenWidth : canvas.frozenHeight
        let length = isColumns ? bounds.width : bounds.height
        let count = isColumns ? geometry.columnCount : geometry.rowCount
        let selected = spreadsheet.session.selection.range
        let selectedSpan = isColumns ? selected.start.column...selected.end.column : selected.start.row...selected.end.row

        func position(_ index: Int) -> (start: CGFloat, size: CGFloat) {
            let start = isColumns ? geometry.x(ofColumn: index) : geometry.y(ofRow: index)
            let size = isColumns ? geometry.columnWidth(index) : geometry.rowHeight(index)
            return index < frozen ? (start, size) : (start - scroll, size)
        }
        var indices = Array(0..<frozen)
        let firstScrolling = max(frozen, (isColumns ? geometry.column(atX: frozenExtent + scroll)
                                                    : geometry.row(atY: frozenExtent + scroll)))
        var index = firstScrolling
        while index < count, position(index).start < length {
            indices.append(index)
            index += 1
        }

        let font = NSFont.systemFont(ofSize: 11 * min(max(geometry.zoom, 0.8), 1.4))
        for index in indices {
            let (start, size) = position(index)
            guard size > 0, index < frozen || start + size > frozenExtent else { continue }
            let rect = isColumns ? CGRect(x: start, y: 0, width: size, height: bounds.height)
                                 : CGRect(x: 0, y: start, width: bounds.width, height: size)
            NSGraphicsContext.saveGraphicsState()
            if index >= frozen {   // 滚动的部分不能盖到冻结的部分上
                (isColumns ? CGRect(x: frozenExtent, y: 0, width: length, height: bounds.height)
                           : CGRect(x: 0, y: frozenExtent, width: bounds.width, height: length)).clip()
            }
            let isSelected = selectedSpan.contains(index)
            if isSelected {
                NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
                rect.fill()
            }
            let label = isColumns ? CellAddress.columnName(index) : String(index + 1)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: isSelected ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
            ]
            let labelSize = (label as NSString).size(withAttributes: attributes)
            (label as NSString).draw(at: CGPoint(x: rect.midX - labelSize.width / 2, y: rect.midY - labelSize.height / 2),
                                     withAttributes: attributes)
            NSColor(white: 0.82, alpha: 1).setFill()
            (isColumns ? CGRect(x: rect.maxX - 1, y: 0, width: 1, height: bounds.height)
                       : CGRect(x: 0, y: rect.maxY - 1, width: bounds.width, height: 1)).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        NSColor(white: 0.78, alpha: 1).setFill()
        (isColumns ? CGRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1)
                   : CGRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height)).fill()
    }
}
