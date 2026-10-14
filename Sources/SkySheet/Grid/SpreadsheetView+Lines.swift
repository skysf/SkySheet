import AppKit
import SkySheetCore
import SkySheetDisplay

/// 列标、行号上的鼠标要表格做的事：选整列整行、拖边线改宽高、双击自动适应（HeaderView 调这些，2026-10-14 加）。
extension SpreadsheetView {
    /// 鼠标按下之前：正在编辑的先提交，键盘交回表格。
    func prepareForMouse() {
        if session.editing != nil { finishEditing(rows: 0, columns: 0) }
        window?.makeFirstResponder(self)
    }

    /// 选整列（整行）。活动格放在看得见的最上面一行（最左边一列），表格不跳。
    func selectLines(_ axis: SheetAxis, through index: Int, extend: Bool) {
        session.selectLines(axis, through: index, extend: extend,
                            crossIndex: firstVisibleLine(axis == .columns ? .rows : .columns))
    }

    /// 看得见的第一行（列）：冻结着的就是第一行，否则是主区滚到的那一行。
    func firstVisibleLine(_ axis: SheetAxis) -> Int {
        guard let canvas else { return 0 }
        switch axis {
        case .rows: return canvas.frozenRows > 0 ? 0 : canvas.geometry.row(atY: scrollOffset.y)
        case .columns: return canvas.frozenColumns > 0 ? 0 : canvas.geometry.column(atX: scrollOffset.x)
        }
    }

    /// 在列标上拖出视图，主区跟着往那边滚，但只在这个方向上：在列标上横着拖，不该让表格往上滚到顶。
    func autoscroll(along axis: SheetAxis, with event: NSEvent) {
        let clip = scrollView.contentView
        var point = clip.convert(event.locationInWindow, from: nil)
        if axis == .columns { point.y = clip.bounds.midY } else { point.x = clip.bounds.midX }
        guard let moved = NSEvent.mouseEvent(with: .leftMouseDragged, location: clip.convert(point, to: nil),
                                             modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                                             windowNumber: event.windowNumber, context: nil, eventNumber: event.eventNumber,
                                             clickCount: event.clickCount, pressure: event.pressure) else { return }
        mainPane.autoscroll(with: moved)
    }

    /// 拖边线：`pixels` 是拖到的大小（屏幕点，当前缩放）。换成 Excel 的单位放进预览：画出来，但还没改工作簿。
    func previewResize(_ axis: SheetAxis, lines: ClosedRange<Int>, pixels: CGFloat, near point: CGPoint) {
        guard let canvas else { return }
        let actual = Double(pixels) / session.zoom
        let size: Double
        let shownPixels: Double
        switch axis {
        case .columns:
            size = min(255, SheetGeometry.columnWidth(forPixels: actual, digitWidth: canvas.digitWidth))
            shownPixels = SheetGeometry.columnPixels(size, digitWidth: canvas.digitWidth)
        case .rows:
            size = min(409, SheetGeometry.rowHeight(forPixels: actual))
            shownPixels = (size * SheetGeometry.pixelsPerPoint).rounded()
        }
        session.resizePreview = ResizePreview(axis: axis, lines: lines, size: size)
        let number = size.formatted(.number.precision(.fractionLength(2)))
        let text = axis == .columns ? String(localized: "Width: \(number) (\(Int(shownPixels)) px)")
                                    : String(localized: "Height: \(number) (\(Int(shownPixels)) px)")
        sizeLabel.show(text, near: point, within: bounds)
    }

    /// 松手：拖到 0 就藏起来（原来的大小留着，取消隐藏时回来），否则改成拖到的大小。一步撤销。
    func finishResize() {
        sizeLabel.isHidden = true
        guard let preview = session.resizePreview else { return }
        session.resizePreview = nil
        if preview.size <= 0 {
            session.setHidden(true, preview.axis, lines: preview.lines)
        } else {
            session.setSize(preview.size, preview.axis, lines: preview.lines)
        }
    }

    /// 双击边线、菜单里的自动适应：按内容定宽（高）。一步撤销。
    func autoFit(_ axis: SheetAxis, lines: ClosedRange<Int>) {
        switch axis {
        case .columns:
            session.setSizes(ContentFit.widths(lines, sheet: session.sheetIndex, in: session, fonts: fonts), .columns,
                             actionName: String(localized: "AutoFit Column Width"))
        case .rows:
            session.setSizes(ContentFit.heights(lines, sheet: session.sheetIndex, in: session, fonts: fonts), .rows,
                             actionName: String(localized: "AutoFit Row Height"))
        }
    }
}

/// 拖边线时跟着鼠标的小牌子。
@MainActor
final class SizeLabel: NSTextField {
    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = true
        backgroundColor = NSColor(white: 1, alpha: 0.95)
        textColor = .labelColor
        font = .systemFont(ofSize: 11)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 0.7, alpha: 1).cgColor
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// 摆在鼠标右下方一点；靠边时往里收，别出了表格。
    func show(_ text: String, near point: CGPoint, within area: CGRect) {
        stringValue = text
        sizeToFit()
        let size = CGSize(width: frame.width + 10, height: frame.height + 4)
        let x = min(max(point.x + 12, area.minX + 2), area.maxX - size.width - 2)
        let y = min(max(point.y + 12, area.minY + 2), area.maxY - size.height - 2)
        frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
        isHidden = false
    }
}
