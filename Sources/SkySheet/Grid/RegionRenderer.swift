import AppKit
import SkySheetCore
import SkySheetDisplay

/// 画 sheet 的一块（若干行 × 若干列）。坐标是 sheet 坐标：调用方已经把画布平移好了。
/// 顺序和 Excel 一样：底色 → 网格线 → 填充（盖住网格线）→ 文字 → 边框 → 选区。合并单元格按一整块画。
///
/// 画一帧要过几百上千个格子，这里的写法照顾速度（2026-11-14，设计 8.2 节「性能」），画出来的和原来一模一样：
/// - 每一行看得见的格子只取一次（SparseGrid.entries(inRow:columns:)），三遍（填充、文字、边框）共用；
/// - 合并单元格查 MergeIndex，不再每格把整张表的合并单元格过一遍；
/// - 循环里不把闭包交给别的模块的函数：主线程上的闭包，Swift 6 每调一次都要核对一遍是不是在主线程上，
///   几千个格子下来比画字还贵（2026-11-14 实测）。要传闭包的放到 nonisolated 的静态函数里。
/// - 画字的属性按样式缓存成 NSDictionary（TextAttributes），一格字只量一次。
///
/// 局部重画（只重画一条：选区移过的那几行、滚动新露出来的条）和整块重画画出来的必须一模一样：
/// - 要画的格子（rows、columns）比重画的范围（clip）往外多看 spill 那么远（PaneView 算好的 `reach`）：旁边的格子画出界的
///   那一点（填充、边框）会落进来；
/// - 三件事按「整块重画时会画的行列」（visibleRows、visibleColumns）来定，而不是按这次要画的行列：合并单元格的边框（画到它
///   左上角那一格时才画，左上角可能不在这次重画的行里）、AI 改过的格子的淡紫色（合并单元格整块盖）、往旁边溢出的长文字
///   （看左右各 32 列）。
/// 整块重画时两边一样，画出来和原来一模一样。局部重画由测速模式的 verify 逐像素核对（BenchmarkVerify）。
@MainActor
struct RegionRenderer {
    let canvas: SheetCanvas
    /// 这次要重画的行列（和 `clip` 相交的）。
    let rows: Range<Int>
    let columns: Range<Int>
    /// 这块窗格整块重画时会画的行列（看得见的）。
    let visibleRows: Range<Int>
    let visibleColumns: Range<Int>
    /// 这块窗格自己的列范围：文字溢出不越过它（冻结列里的字不溢到滚动区去）。
    let paneColumns: Range<Int>
    /// 要画的格子覆盖的范围（clip 往外多看 spill）：合并单元格按它挑。
    let reach: CGRect
    /// 这次重画的范围（sheet 坐标）。
    let clip: CGRect

    private var geometry: SheetGeometry { canvas.geometry }
    private var padding: CGFloat { 2 * geometry.zoom }

    func draw(selection: Selection?) {
        NSColor.white.setFill()
        clip.fill()
        guard !rows.isEmpty, !columns.isEmpty else { return }
        let merges = canvas.merges(intersecting: reach)
        var lines: [[(column: Int, value: Cell)]] = []
        lines.reserveCapacity(rows.count)
        for row in rows {
            lines.append(canvas.sheet.cells.entries(inRow: row, columns: columns))
        }
        drawGridLines()
        drawFills(lines, merges)
        drawAITouched()
        drawText(merges)
        drawBorders(lines, merges)
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
    private func drawFills(_ lines: [[(column: Int, value: Cell)]], _ merges: [CellRange]) {
        for (offset, line) in lines.enumerated() {
            let row = rows.lowerBound + offset
            for (column, cell) in line {
                let address = CellAddress(row: row, column: column)
                guard let fill = canvas.styles.style(cell.styleIndex).fill, !Self.contains(merges, address) else { continue }
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
        for address in canvas.aiTouched where visibleRows.contains(address.row) && visibleColumns.contains(address.column) {
            canvas.rect(of: canvas.merge(containing: address) ?? CellRange(address)).fill()
        }
    }

    // MARK: - 文字

    private func drawText(_ merges: [CellRange]) {
        // 看得见的列左右各多看 32 列：左边格子里的长文字可能溢进来，右对齐的也可能从右边溢进来。
        let scan = max(paneColumns.lowerBound, visibleColumns.lowerBound - 32)
            ..< min(paneColumns.upperBound, visibleColumns.upperBound + 32)
        for row in rows {
            for (column, cell) in canvas.sheet.cells.entries(inRow: row, columns: scan) {
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
        let (content, style) = canvas.content(of: cell, at: address)
        guard content.kind != .empty, !content.text.isEmpty else { return }
        let attributes = canvas.textAttributes(cell, style: style, content: content)

        if style.wrapText, content.kind == .text {
            drawWrapped(attributes.line(content.text), in: rect.insetBy(dx: padding, dy: 1), vertical: style.vertical)
            return
        }
        // 量一次：放得下（绝大多数）就是它；数字放不下才按「常规」缩短或者变成 ###（CellDisplay.fitNumber）。
        var text = content.text
        var size = attributes.size(of: text)
        let room = rect.width - 2 * padding
        if content.kind == .number, size.width > room {
            text = attributes.fit(content, width: room)
            size = attributes.size(of: text)
        }
        var area = rect
        if canOverflow, content.kind == .text, size.width > rect.width - 2 * padding {
            let span = Self.overflowSpan(column: address.column, row: address.row, textWidth: size.width + 2 * padding,
                                         placement: content.placement, geometry: geometry, cells: canvas.sheet.cells,
                                         merges: canvas.mergeIndex, paneColumns: paneColumns)
            area = canvas.rect(of: CellRange(CellAddress(row: address.row, column: span.lowerBound),
                                             CellAddress(row: address.row, column: span.upperBound)))
        }
        // 这一格在这次重画的范围里一点都没有（或者它本身没有大小：藏起来的行列）就不画：拿空的、null 的框去裁剪
        // 等于没裁（见 drawWrapped）。
        let visible = area.intersection(clip)
        guard !visible.isEmpty else { return }
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
        visible.clip()
        attributes.line(text).draw(at: CGPoint(x: x, y: y))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 自动换行的字，裁在格子里（上下各多 1 点）。两种情况不画（2026-11-15，verify 复现）：
    /// - 格子扣掉边距以后没地方了（藏起来的行高 0、比边距还窄的列）：框成了 null，原点在无穷远，排出来的字全挤到裁剪框的
    ///   一角，成了一团黑块；
    /// - 格子和这次重画的范围不相交（局部重画时在重画的条外面）：`NSRectClip` 拿 null 的框裁剪等于没裁，它下面那几行字会
    ///   画进重画的条里，盖在别的格子上。
    /// 两种情况整块重画时也一样不画；这一格本来也一点都看不见。
    private func drawWrapped(_ line: NSAttributedString, in rect: CGRect, vertical: VerticalAlignment) {
        let visible = rect.insetBy(dx: -padding, dy: -1).intersection(clip)
        guard !rect.isEmpty, !visible.isEmpty else { return }
        let bounding = line.boundingRect(with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin], context: nil)
        let height = min(bounding.height, rect.height)
        let y: CGFloat = switch vertical {
        case .top: rect.minY
        case .center, .justify, .distributed: rect.midY - height / 2
        case .bottom: rect.maxY - height
        }
        NSGraphicsContext.saveGraphicsState()
        visible.clip()
        line.draw(with: CGRect(x: rect.minX, y: y, width: rect.width, height: bounding.height),
                  options: [.usesLineFragmentOrigin], context: nil)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 文字往旁边空格子溢出能占到哪几列（CellDisplay.overflowColumns）。闭包在这里（nonisolated）建，不带主线程检查。
    private nonisolated static func overflowSpan(column: Int, row: Int, textWidth: Double, placement: HorizontalPlacement,
                                                geometry: SheetGeometry, cells: SparseGrid<Cell>, merges: MergeIndex,
                                                paneColumns: Range<Int>) -> ClosedRange<Int> {
        CellDisplay.overflowColumns(
            column: column, textWidth: textWidth, placement: placement,
            columnWidth: { geometry.columnWidth($0) },
            isEmpty: { neighbour in
                guard paneColumns.contains(neighbour) else { return false }
                let address = CellAddress(row: row, column: neighbour)
                if let cell = cells[address], cell.value != .empty { return false }
                return merges.merge(containing: address) == nil
            },
            columnCount: paneColumns.upperBound)
    }

    // MARK: - 边框和选区

    /// 每个格子画自己的四条边；合并单元格用左上角那一格的样式画整块的外框，里面的格子不画。
    /// 合并单元格的外框在轮到左上角那一格时画。局部重画时左上角看得见、却不在这次重画的行列里的，照样画（裁在重画的
    /// 范围里），按左上角的位置排进先后顺序：和整块重画时一样的先后，盖在一起的边框颜色才一样。
    private func drawBorders(_ lines: [[(column: Int, value: Cell)]], _ merges: [CellRange]) {
        var outside: [(merge: CellRange, cell: Cell)] = []
        for merge in merges {
            let start = merge.start
            guard visibleRows.contains(start.row), visibleColumns.contains(start.column),
                  !(rows.contains(start.row) && columns.contains(start.column)),
                  canvas.merge(containing: start) == merge, let cell = canvas.sheet.cells[start] else { continue }
            outside.append((merge, cell))
        }
        outside.sort { $0.merge.start < $1.merge.start }
        var next = 0
        for (offset, line) in lines.enumerated() {
            let row = rows.lowerBound + offset
            for (column, cell) in line {
                let address = CellAddress(row: row, column: column)
                while next < outside.count, outside[next].merge.start < address {
                    strokeEdges(canvas.styles.style(outside[next].cell.styleIndex), canvas.rect(of: outside[next].merge))
                    next += 1
                }
                if let merge = Self.first(merges, containing: address) {
                    if merge.start == address { strokeEdges(canvas.styles.style(cell.styleIndex), canvas.rect(of: merge)) }
                    continue
                }
                strokeEdges(canvas.styles.style(cell.styleIndex), canvas.rect(of: CellRange(address)))
            }
        }
        while next < outside.count {
            strokeEdges(canvas.styles.style(outside[next].cell.styleIndex), canvas.rect(of: outside[next].merge))
            next += 1
        }
    }

    private func strokeEdges(_ style: ResolvedStyle, _ rect: CGRect) {
        guard style.left != nil || style.right != nil || style.top != nil || style.bottom != nil else { return }
        stroke(style.left, from: CGPoint(x: rect.minX - 0.5, y: rect.minY), to: CGPoint(x: rect.minX - 0.5, y: rect.maxY))
        stroke(style.right, from: CGPoint(x: rect.maxX - 0.5, y: rect.minY), to: CGPoint(x: rect.maxX - 0.5, y: rect.maxY))
        stroke(style.top, from: CGPoint(x: rect.minX, y: rect.minY - 0.5), to: CGPoint(x: rect.maxX, y: rect.minY - 0.5))
        stroke(style.bottom, from: CGPoint(x: rect.minX, y: rect.maxY - 0.5), to: CGPoint(x: rect.maxX, y: rect.maxY - 0.5))
    }

    private func stroke(_ edge: ResolvedEdge?, from: CGPoint, to: CGPoint) {
        guard let edge else { return }
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

    // MARK: - 小工具（不用闭包，见类型说明）

    private static func contains(_ merges: [CellRange], _ address: CellAddress) -> Bool {
        first(merges, containing: address) != nil
    }

    private static func first(_ merges: [CellRange], containing address: CellAddress) -> CellRange? {
        for merge in merges where merge.contains(address) { return merge }
        return nil
    }
}
