import AppKit
import SkySheetCore
import SkySheetDisplay

/// 画 sheet 的一块（若干行 × 若干列）。坐标是 sheet 坐标：调用方已经把画布平移好了。
/// 顺序和 Excel 一样：底色 → 网格线 → 填充（盖住网格线）→ 文字 → 边框 → 选区。合并单元格按一整块画。
@MainActor
struct RegionRenderer {
    let canvas: SheetCanvas
    let rows: Range<Int>
    let columns: Range<Int>
    /// 这块窗格自己的列范围：文字溢出不越过它（冻结列里的字不溢到滚动区去）。
    let paneColumns: Range<Int>
    let clip: CGRect

    private var geometry: SheetGeometry { canvas.geometry }
    private var padding: CGFloat { 2 * geometry.zoom }

    func draw(selection: Selection?) {
        NSColor.white.setFill()
        clip.fill()
        guard !rows.isEmpty, !columns.isEmpty else { return }
        let merges = canvas.sheet.merges.filter { canvas.rect(of: $0).intersects(clip) }
        drawGridLines()
        drawFills(merges)
        drawAITouched()
        drawText(merges)
        drawBorders(merges)
        if let selection { drawSelection(selection) }
    }

    // MARK: - 网格线和填充

    private func drawGridLines() {
        let path = NSBezierPath()
        let top = geometry.y(ofRow: rows.lowerBound)
        let bottom = geometry.y(ofRow: rows.upperBound)
        let left = geometry.x(ofColumn: columns.lowerBound)
        let right = geometry.x(ofColumn: columns.upperBound)
        for column in columns {
            let x = geometry.x(ofColumn: column + 1) - 0.5
            path.move(to: CGPoint(x: x, y: top))
            path.line(to: CGPoint(x: x, y: bottom))
        }
        for row in rows {
            let y = geometry.y(ofRow: row + 1) - 0.5
            path.move(to: CGPoint(x: left, y: y))
            path.line(to: CGPoint(x: right, y: y))
        }
        path.lineWidth = 1
        NSColor(white: 0.88, alpha: 1).setStroke()
        path.stroke()
    }

    /// 有填充的格子盖住自己四周的网格线（和 Excel 一样）；合并单元格整块填（没填充就填白，盖掉里面的网格线）。
    private func drawFills(_ merges: [CellRange]) {
        for row in rows {
            for (column, cell) in canvas.sheet.cells.row(row) where columns.contains(column) {
                let address = CellAddress(row: row, column: column)
                guard let fill = canvas.styles.style(cell.styleIndex).fill,
                      !merges.contains(where: { $0.contains(address) }) else { continue }
                NSColor(fill).setFill()
                canvas.rect(of: CellRange(address)).insetBy(dx: -0.5, dy: -0.5).fill()
            }
        }
        for merge in merges {
            let style = canvas.styles.style(canvas.sheet.cells[merge.start]?.styleIndex ?? 0)
            (style.fill.map(NSColor.init) ?? .white).setFill()
            canvas.rect(of: merge).insetBy(dx: -0.5, dy: -0.5).fill()
        }
    }

    /// 这一轮 AI 改过的格子盖一层淡紫色（和 AI 的 sheet 页签一个颜色），下一轮开始时消失、不存进文件。
    private func drawAITouched() {
        guard !canvas.aiTouched.isEmpty else { return }
        NSColor.systemPurple.withAlphaComponent(0.13).setFill()
        for address in canvas.aiTouched where rows.contains(address.row) && columns.contains(address.column) {
            canvas.rect(of: canvas.merge(containing: address) ?? CellRange(address)).fill()
        }
    }

    // MARK: - 文字

    private func drawText(_ merges: [CellRange]) {
        // 看得见的列左右各多看 32 列：左边格子里的长文字可能溢进来，右对齐的也可能从右边溢进来。
        let scan = max(paneColumns.lowerBound, columns.lowerBound - 32)..<min(paneColumns.upperBound, columns.upperBound + 32)
        for row in rows {
            for (column, cell) in canvas.sheet.cells.row(row) where scan.contains(column) {
                let address = CellAddress(row: row, column: column)
                guard canvas.merge(containing: address) == nil else { continue }
                draw(cell, at: address, in: canvas.rect(of: CellRange(address)), canOverflow: true)
            }
        }
        for merge in merges {
            if let cell = canvas.sheet.cells[merge.start] {
                draw(cell, at: merge.start, in: canvas.rect(of: merge), canOverflow: false)
            }
        }
    }

    private func draw(_ cell: Cell, at address: CellAddress, in rect: CGRect, canOverflow: Bool) {
        let (content, style) = canvas.content(of: cell)
        guard content.kind != .empty, !content.text.isEmpty else { return }
        let attributes = textAttributes(style, color: content.color, placement: content.placement)
        let measure: (String) -> Double = { ($0 as NSString).size(withAttributes: attributes).width }

        if style.wrapText, content.kind == .text {
            drawWrapped(content.text, attributes: attributes, in: rect.insetBy(dx: padding, dy: 1), vertical: style.vertical)
            return
        }
        let text = CellDisplay.fitNumber(content, width: rect.width - 2 * padding, measure: measure)
        let size = (text as NSString).size(withAttributes: attributes)
        var area = rect
        if canOverflow, content.kind == .text, size.width > rect.width - 2 * padding {
            let span = CellDisplay.overflowColumns(
                column: address.column, textWidth: size.width + 2 * padding, placement: content.placement,
                columnWidth: { geometry.columnWidth($0) },
                isEmpty: { paneColumns.contains($0) && canvas.isEmpty(row: address.row, column: $0) },
                columnCount: paneColumns.upperBound)
            area = canvas.rect(of: CellRange(CellAddress(row: address.row, column: span.lowerBound),
                                             CellAddress(row: address.row, column: span.upperBound)))
        }
        guard area.intersects(clip) else { return }
        let x: CGFloat = switch content.placement {
        case .left: area.minX + padding
        case .center: area.midX - size.width / 2
        case .right: area.maxX - padding - size.width
        }
        let y: CGFloat = switch style.vertical {
        case .top: rect.minY + 1
        case .center, .justify, .distributed: rect.midY - size.height / 2
        case .bottom: rect.maxY - size.height - 1
        }
        NSGraphicsContext.saveGraphicsState()
        area.intersection(clip).clip()
        (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawWrapped(_ text: String, attributes: [NSAttributedString.Key: Any], in rect: CGRect,
                             vertical: VerticalAlignment) {
        let bounding = (text as NSString).boundingRect(with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
                                                       options: [.usesLineFragmentOrigin], attributes: attributes)
        let height = min(bounding.height, rect.height)
        let y: CGFloat = switch vertical {
        case .top: rect.minY
        case .center, .justify, .distributed: rect.midY - height / 2
        case .bottom: rect.maxY - height
        }
        NSGraphicsContext.saveGraphicsState()
        rect.insetBy(dx: -padding, dy: -1).intersection(clip).clip()
        (text as NSString).draw(with: CGRect(x: rect.minX, y: y, width: rect.width, height: bounding.height),
                                options: [.usesLineFragmentOrigin], attributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func textAttributes(_ style: ResolvedStyle, color: RGBAColor,
                                placement: HorizontalPlacement) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = switch placement {
        case .left: .left
        case .center: .center
        case .right: .right
        }
        paragraph.lineBreakMode = .byWordWrapping
        var attributes: [NSAttributedString.Key: Any] = [
            .font: canvas.fonts.font(style.font, points: geometry.fontPoints(style.font.size)),
            .foregroundColor: NSColor(color),
            .paragraphStyle: paragraph,
        ]
        if style.font.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if style.font.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return attributes
    }

    // MARK: - 边框和选区

    /// 每个格子画自己的四条边；合并单元格用左上角那一格的样式画整块的外框，里面的格子不画。
    private func drawBorders(_ merges: [CellRange]) {
        for row in rows {
            for (column, cell) in canvas.sheet.cells.row(row) where columns.contains(column) {
                let address = CellAddress(row: row, column: column)
                if let merge = merges.first(where: { $0.contains(address) }) {
                    if merge.start == address { strokeEdges(canvas.styles.style(cell.styleIndex), canvas.rect(of: merge)) }
                    continue
                }
                strokeEdges(canvas.styles.style(cell.styleIndex), canvas.rect(of: CellRange(address)))
            }
        }
    }

    private func strokeEdges(_ style: ResolvedStyle, _ rect: CGRect) {
        let edges: [(ResolvedEdge?, CGPoint, CGPoint)] = [
            (style.left, CGPoint(x: rect.minX - 0.5, y: rect.minY), CGPoint(x: rect.minX - 0.5, y: rect.maxY)),
            (style.right, CGPoint(x: rect.maxX - 0.5, y: rect.minY), CGPoint(x: rect.maxX - 0.5, y: rect.maxY)),
            (style.top, CGPoint(x: rect.minX, y: rect.minY - 0.5), CGPoint(x: rect.maxX, y: rect.minY - 0.5)),
            (style.bottom, CGPoint(x: rect.minX, y: rect.maxY - 0.5), CGPoint(x: rect.maxX, y: rect.maxY - 0.5)),
        ]
        for case let (edge?, from, to) in edges {
            let path = NSBezierPath()
            path.move(to: from)
            path.line(to: to)
            path.lineWidth = max(1, edge.width * geometry.zoom)
            switch edge.pattern {
            case .dashed: path.setLineDash([3, 2], count: 2, phase: 0)
            case .dotted: path.setLineDash([1, 1], count: 2, phase: 0)
            case .solid, .double: break
            }
            NSColor(edge.color).setStroke()
            path.stroke()
        }
    }

    private func drawSelection(_ selection: Selection) {
        let range = canvas.rect(of: selection.range)
        guard range.intersects(clip.insetBy(dx: -3, dy: -3)) else { return }
        let cursor = canvas.rect(of: canvas.merge(containing: selection.cursor) ?? CellRange(selection.cursor))
        let shade = NSBezierPath(rect: range)
        shade.append(NSBezierPath(rect: cursor))
        shade.windingRule = .evenOdd
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        shade.fill()
        let outline = NSBezierPath(rect: range.insetBy(dx: 0, dy: 0))
        outline.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        outline.stroke()
    }
}
