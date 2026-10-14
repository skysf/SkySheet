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

    /// 右键菜单由表格视图统一给（点在哪一格它来算）。
    override func menu(for event: NSEvent) -> NSMenu? {
        spreadsheet?.menu(for: event)
    }

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
