import AppKit
import SkySheetCore
import SkySheetDisplay

/// 列标（A、B、C…）或行号（1、2、3…）。冻结的部分不动，其余跟着主区滚。选中的那几行 / 几列加深显示，整列整行选中时
/// 再深一点；藏起来的行列在它的位置上画一道深色的线（和 Excel 一样，提醒那里有东西）。
///
/// 鼠标（2026-10-14 加，设计 8.2 节）：点一下选整列（行），Shift 点或拖着选好几列；在两列之间的边线上拖，改左边那一列的
/// 宽度（选着好几整列、拖的是其中一列时一起改，和 Excel 一样），拖到 0 就藏起来；双击边线按内容自动定宽；右键是插删、
/// 宽高、隐藏的菜单。
@MainActor
final class HeaderView: NSView {
    let axis: SheetAxis
    weak var spreadsheet: SpreadsheetView?

    /// 主区滚了多远（这个方向上）。
    var scroll: CGFloat = 0 {
        didSet {
            guard scroll != oldValue else { return }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    /// 边线左右（上下）各这么宽都算按在边线上。
    private static let edgeSlop: CGFloat = 4

    private enum Tracking {
        case selecting
        case resizing(lines: ClosedRange<Int>, startSize: CGFloat, startPosition: CGFloat)
    }

    private var tracking: Tracking?

    init(axis: SheetAxis) {
        self.axis = axis
        super.init(frame: .zero)
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    // MARK: - 排布

    /// 一条看得见的行（列）：序号、在这块视图里从哪开始、多大（藏起来的是 0）。
    struct Item {
        let index: Int
        let start: CGFloat
        let size: CGFloat
    }

    /// 冻结的几条，加上滚到视图里的那几条。
    private func items() -> [Item] {
        guard let canvas = spreadsheet?.canvas else { return [] }
        let geometry = canvas.geometry
        let isColumns = axis == .columns
        let frozen = isColumns ? canvas.frozenColumns : canvas.frozenRows
        let frozenExtent = isColumns ? canvas.frozenWidth : canvas.frozenHeight
        let length = isColumns ? bounds.width : bounds.height
        let count = isColumns ? geometry.columnCount : geometry.rowCount
        func item(_ index: Int) -> Item {
            let start = isColumns ? geometry.x(ofColumn: index) : geometry.y(ofRow: index)
            let size = isColumns ? geometry.columnWidth(index) : geometry.rowHeight(index)
            return Item(index: index, start: index < frozen ? start : start - scroll, size: size)
        }
        var result = (0..<frozen).map(item)
        var index = max(frozen, isColumns ? geometry.column(atX: frozenExtent + scroll) : geometry.row(atY: frozenExtent + scroll))
        // 藏起来的几条在可见的第一条前面：往回找，好把那道线画出来。
        while index > frozen, item(index - 1).size == 0 { index -= 1 }
        while index < count {
            let next = item(index)
            guard next.start < length else { break }
            result.append(next)
            index += 1
        }
        return result
    }

    /// 冻结区和滚动区的分界（这个方向上）：滚动的部分不能盖到冻结的部分上。
    private var frozenExtent: CGFloat {
        guard let canvas = spreadsheet?.canvas else { return 0 }
        return axis == .columns ? canvas.frozenWidth : canvas.frozenHeight
    }

    private func position(of point: CGPoint) -> CGFloat {
        axis == .columns ? point.x : point.y
    }

    /// 按在哪条边线上：返回边线左边（上面）那一行（列）。藏起来的不算，拖的总是看得见的那一条。
    private func edge(at point: CGPoint) -> Item? {
        let target = position(of: point)
        let extent = frozenExtent
        let frozenCount = axis == .columns ? (spreadsheet?.canvas?.frozenColumns ?? 0) : (spreadsheet?.canvas?.frozenRows ?? 0)
        var best: (item: Item, distance: CGFloat)?
        for item in items() where item.size > 0 {
            let end = item.start + item.size
            guard item.index < frozenCount || end > extent else { continue }
            let distance = abs(target - end)
            if distance <= Self.edgeSlop, distance < (best?.distance ?? .infinity) { best = (item, distance) }
        }
        return best?.item
    }

    /// 这一点落在哪一行（列）上（拖出视图以后也算：按主区滚到的地方换算）。
    private func line(at point: CGPoint) -> Int? {
        guard let spreadsheet, let address = spreadsheet.address(at: convert(point, to: spreadsheet)) else { return nil }
        return axis.index(of: address)
    }

    // MARK: - 画

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.965, alpha: 1).setFill()
        bounds.fill()
        guard let spreadsheet, let canvas = spreadsheet.canvas else { return }
        let isColumns = axis == .columns
        let frozen = isColumns ? canvas.frozenColumns : canvas.frozenRows
        let extent = frozenExtent
        let length = isColumns ? bounds.width : bounds.height
        let selection = spreadsheet.session.selection
        let selectedSpan = selection.lines(axis)
        let wholeLines = selection.isWhole(axis)

        let font = NSFont.systemFont(ofSize: 11 * min(max(canvas.geometry.zoom, 0.8), 1.4))
        for item in items() {
            guard item.index < frozen || item.start + item.size > extent || item.size == 0 else { continue }
            let rect = isColumns ? CGRect(x: item.start, y: 0, width: item.size, height: bounds.height)
                                 : CGRect(x: 0, y: item.start, width: bounds.width, height: item.size)
            NSGraphicsContext.saveGraphicsState()
            if item.index >= frozen {   // 滚动的部分不能盖到冻结的部分上
                (isColumns ? CGRect(x: extent, y: 0, width: length, height: bounds.height)
                           : CGRect(x: 0, y: extent, width: bounds.width, height: length)).clip()
            }
            if item.size == 0 {
                // 藏起来的：在它的位置上画一道深色的线。
                NSColor(white: 0.45, alpha: 1).setFill()
                (isColumns ? CGRect(x: item.start - 1.5, y: 0, width: 2, height: bounds.height)
                           : CGRect(x: 0, y: item.start - 1.5, width: bounds.width, height: 2)).fill()
                NSGraphicsContext.restoreGraphicsState()
                continue
            }
            let isSelected = selectedSpan.contains(item.index)
            if isSelected {
                NSColor.controlAccentColor.withAlphaComponent(wholeLines ? 0.32 : 0.18).setFill()
                rect.fill()
            }
            let label = isColumns ? CellAddress.columnName(item.index) : String(item.index + 1)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: wholeLines && isSelected ? NSFont.boldSystemFont(ofSize: font.pointSize) : font,
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

    /// 边线上的鼠标是左右（上下）拖的样子。
    override func resetCursorRects() {
        let cursor: NSCursor = axis == .columns ? .columnResize : .rowResize
        let extent = frozenExtent
        let frozenCount = axis == .columns ? (spreadsheet?.canvas?.frozenColumns ?? 0) : (spreadsheet?.canvas?.frozenRows ?? 0)
        for item in items() where item.size > 0 {
            let end = item.start + item.size
            guard item.index < frozenCount || end > extent else { continue }
            addCursorRect(axis == .columns ? CGRect(x: end - Self.edgeSlop, y: 0, width: 2 * Self.edgeSlop, height: bounds.height)
                                           : CGRect(x: 0, y: end - Self.edgeSlop, width: bounds.width, height: 2 * Self.edgeSlop),
                          cursor: cursor)
        }
    }

    // MARK: - 鼠标

    override func mouseDown(with event: NSEvent) {
        guard let spreadsheet else { return }
        spreadsheet.prepareForMouse()
        let point = convert(event.locationInWindow, from: nil)
        if let item = edge(at: point) {
            // 拖的是选着的整列里的一列：一起改。
            let selection = spreadsheet.session.selection
            let lines = selection.isWhole(axis) && selection.lines(axis).contains(item.index)
                ? selection.lines(axis) : item.index...item.index
            if event.clickCount == 2 {
                tracking = nil
                spreadsheet.autoFit(axis, lines: lines)
            } else {
                tracking = .resizing(lines: lines, startSize: item.size, startPosition: position(of: point))
            }
            return
        }
        guard let index = line(at: point) else { return }
        spreadsheet.selectLines(axis, through: index, extend: event.modifierFlags.contains(.shift))
        tracking = .selecting
    }

    override func mouseDragged(with event: NSEvent) {
        guard let spreadsheet else { return }
        let point = convert(event.locationInWindow, from: nil)
        switch tracking {
        case .resizing(let lines, let startSize, let startPosition):
            spreadsheet.previewResize(axis, lines: lines, pixels: max(0, startSize + position(of: point) - startPosition),
                                      near: convert(point, to: spreadsheet))
        case .selecting:
            spreadsheet.autoscroll(along: axis, with: event)
            if let index = line(at: point) { spreadsheet.selectLines(axis, through: index, extend: true) }
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .resizing = tracking { spreadsheet?.finishResize() }
        tracking = nil
    }

    /// 右键：点在没选中的列上先选中它（和 Excel 一样），再弹插删、宽高、隐藏的菜单。
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let spreadsheet, let index = line(at: convert(event.locationInWindow, from: nil)) else { return nil }
        let selection = spreadsheet.session.selection
        if !(selection.isWhole(axis) && selection.lines(axis).contains(index)) {
            spreadsheet.prepareForMouse()
            spreadsheet.selectLines(axis, through: index, extend: false)
        }
        return spreadsheet.headerMenu(axis)
    }
}
