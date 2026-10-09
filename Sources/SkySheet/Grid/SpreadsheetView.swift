import AppKit
import SkySheetCore
import SkySheetDisplay

/// 表格区域（设计 8.2 节）：行号列标、冻结窗格、可以滚动的格子。
///
/// ```
/// ┌──────┬──────────────────────────┐
/// │ 角   │ 列标（冻结的不动，其余跟着滚）  │
/// ├──────┼────────┬─────────────────┤
/// │      │ corner │ frozenRows（左右滚）│
/// │ 行号 ├────────┼─────────────────┤
/// │      │ frozen │ main             │
/// │      │ Columns│（NSScrollView）    │
/// └──────┴────────┴─────────────────┘
/// ```
/// 四块窗格都由 RegionRenderer 画，只是各自对应 sheet 的不同部分。
@MainActor
final class SpreadsheetView: NSView {
    let session: SheetSession
    private(set) var canvas: SheetCanvas?

    let scrollView = NSScrollView()
    let mainPane = MainPaneView(role: .main)
    private let cornerPane = PaneView(role: .corner)
    private let frozenRowsPane = PaneView(role: .frozenRows)
    private let frozenColumnsPane = PaneView(role: .frozenColumns)
    private let columnHeader = HeaderView(axis: .columns)
    private let rowHeader = HeaderView(axis: .rows)
    private let cornerBox = CornerBox()
    /// 格内编辑框（CellEditor.swift）。不编辑时藏着。
    let editor = CellEditor()
    /// 正在处理的按键：开始打字时要把这一下转给编辑框（SpreadsheetView+Input）。
    var pendingKeyEvent: NSEvent?

    static let columnHeaderHeight: CGFloat = 22
    /// 第一次排好之后要不要滚到活动格（选区在视图建好之前就定了的时候，比如换 sheet、截图模式的 --select）。
    private var needsInitialScroll = true

    init(session: SheetSession) {
        self.session = session
        super.init(frame: .zero)
        clipsToBounds = true
        cornerBox.clipsToBounds = true
        for pane in [cornerPane, frozenRowsPane, frozenColumnsPane, mainPane] { pane.spreadsheet = self }
        columnHeader.spreadsheet = self
        rowHeader.spreadsheet = self
        cornerBox.spreadsheet = self

        scrollView.documentView = mainPane
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .white
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(contentScrolled),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        editor.spreadsheet = self
        for view in [scrollView, cornerPane, frozenRowsPane, frozenColumnsPane, columnHeader, rowHeader, cornerBox,
                     editor] as [NSView] {
            addSubview(view)
        }
        rebuildCanvas()
        observeChanges(self, read: { view in
            _ = view.session.sheetIndex
            _ = view.session.zoom
            _ = view.session.workbook
            _ = view.session.aiTouched
        }, onChange: { view in
            view.rebuildCanvas()
        })
        observeChanges(self, read: { view in
            _ = view.session.editing
        }, onChange: { view in
            view.editingChanged()
        })
        observeChanges(self, read: { view in
            _ = view.session.selection
        }, onChange: { view in
            view.selectionChanged()
        })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// 每块窗格对应 sheet 的哪些行、哪些列。
    func cellRanges(for role: PaneView.Role) -> (rows: Range<Int>, columns: Range<Int>) {
        guard let canvas else { return (0..<0, 0..<0) }
        let rowCount = canvas.geometry.rowCount
        let columnCount = canvas.geometry.columnCount
        let frozenRows = canvas.frozenRows
        let frozenColumns = canvas.frozenColumns
        switch role {
        case .corner: return (0..<frozenRows, 0..<frozenColumns)
        case .frozenRows: return (0..<frozenRows, frozenColumns..<columnCount)
        case .frozenColumns: return (frozenRows..<rowCount, 0..<frozenColumns)
        case .main: return (frozenRows..<rowCount, frozenColumns..<columnCount)
        }
    }

    /// 行号那一栏多宽：按最大的行号有几位算。
    var rowHeaderWidth: CGFloat {
        let digits = String(canvas?.geometry.rowCount ?? 100).count
        return max(36, CGFloat(digits) * 8 + 14)
    }

    /// 主区滚到哪了。
    var scrollOffset: CGPoint { scrollView.contentView.bounds.origin }

    // MARK: - 排布

    private func rebuildCanvas() {
        canvas = SheetCanvas(session: session)
        needsLayout = true
        needsInitialScroll = true
        for view in [cornerPane, frozenRowsPane, frozenColumnsPane, mainPane, columnHeader, rowHeader] as [NSView] {
            view.needsDisplay = true
        }
    }

    override func layout() {
        super.layout()
        guard let canvas else { return }
        let headerHeight = Self.columnHeaderHeight
        let headerWidth = rowHeaderWidth
        let frozenWidth = canvas.frozenWidth
        let frozenHeight = canvas.frozenHeight
        let gridX = headerWidth
        let gridY = headerHeight
        let restWidth = max(0, bounds.width - gridX - frozenWidth)
        let restHeight = max(0, bounds.height - gridY - frozenHeight)

        cornerBox.frame = CGRect(x: 0, y: 0, width: headerWidth, height: headerHeight)
        columnHeader.frame = CGRect(x: gridX, y: 0, width: bounds.width - gridX, height: headerHeight)
        rowHeader.frame = CGRect(x: 0, y: gridY, width: headerWidth, height: bounds.height - gridY)
        cornerPane.frame = CGRect(x: gridX, y: gridY, width: frozenWidth, height: frozenHeight)
        frozenRowsPane.frame = CGRect(x: gridX + frozenWidth, y: gridY, width: restWidth, height: frozenHeight)
        frozenColumnsPane.frame = CGRect(x: gridX, y: gridY + frozenHeight, width: frozenWidth, height: restHeight)
        scrollView.frame = CGRect(x: gridX + frozenWidth, y: gridY + frozenHeight, width: restWidth, height: restHeight)
        mainPane.frame = CGRect(x: 0, y: 0, width: max(restWidth, canvas.geometry.totalWidth - frozenWidth),
                                height: max(restHeight, canvas.geometry.totalHeight - frozenHeight))
        mainPane.origin = CGPoint(x: frozenWidth, y: frozenHeight)
        syncToScroll()
        if needsInitialScroll, bounds.width > 0, bounds.height > 0 {
            needsInitialScroll = false
            scrollToCursor()
        }
    }

    @objc private func contentScrolled() {
        syncToScroll()
    }

    /// 主区滚了：冻结行左右跟、冻结列上下跟、行号列标跟着走。
    private func syncToScroll() {
        guard let canvas else { return }
        let offset = scrollOffset
        frozenRowsPane.origin = CGPoint(x: canvas.frozenWidth + offset.x, y: 0)
        frozenColumnsPane.origin = CGPoint(x: 0, y: canvas.frozenHeight + offset.y)
        columnHeader.scroll = offset.x
        rowHeader.scroll = offset.y
        if session.editing != nil { placeEditor() }
    }

    private func selectionChanged() {
        for view in [cornerPane, frozenRowsPane, frozenColumnsPane, mainPane, columnHeader, rowHeader] as [NSView] {
            view.needsDisplay = true
        }
        scrollToCursor()
    }

    /// 让活动格露出来。冻结区里的格子本来就看得见，只在滚动的那个方向上挪。
    func scrollToCursor() {
        guard let canvas else { return }
        let cursor = session.selection.cursor
        let rect = canvas.rect(of: canvas.merge(containing: cursor) ?? CellRange(cursor))
        let visible = scrollView.contentView.bounds
        var target = visible
        if cursor.column >= canvas.frozenColumns {
            target.origin.x = rect.minX - canvas.frozenWidth
            target.size.width = rect.width
        }
        if cursor.row >= canvas.frozenRows {
            target.origin.y = rect.minY - canvas.frozenHeight
            target.size.height = rect.height
        }
        mainPane.scrollToVisible(target)
    }

    /// SpreadsheetView 坐标里的一点落在哪一格（冻结区不加滚动距离，其余加上）。
    func address(at point: CGPoint) -> CellAddress? {
        guard let canvas else { return nil }
        let x = point.x - rowHeaderWidth
        let y = point.y - Self.columnHeaderHeight
        let sheetX = x < canvas.frozenWidth ? x : x + scrollOffset.x
        let sheetY = y < canvas.frozenHeight ? y : y + scrollOffset.y
        return CellAddress(row: canvas.geometry.row(atY: max(sheetY, 0)),
                           column: canvas.geometry.column(atX: max(sheetX, 0)))
    }
}

/// 左上角那个小方块：点它全选。
@MainActor
final class CornerBox: NSView {
    weak var spreadsheet: SpreadsheetView?

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.93, alpha: 1).setFill()
        bounds.fill()
        NSColor(white: 0.78, alpha: 1).setFill()
        CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        CGRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
    }

    override func mouseDown(with event: NSEvent) {
        spreadsheet?.session.selectAll()
    }
}
