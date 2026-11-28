import SwiftUI
import UIKit
import SkyFolioTheme
import SkySheetCore
import SkySheetDisplay

/// 只生成屏幕范围内的按钮。稀疏表里相距很远的两个格子不会撑出成千上万个视图。
struct WorkbookGrid: View {
    let book: MobileWorkbook
    @Binding var position: ScrollPosition
    @Binding var viewport: CGRect
    let picking: Bool
    let tap: (CellAddress) -> Void
    let pickRange: (CellRange) -> Void
    static let gutter = 46.0
    static let header = 28.0

    var body: some View {
        let grid = book.geometry
        let rows = grid.row(atY: max(0, viewport.minY - Self.header))...grid.row(atY: max(0, viewport.maxY - Self.header))
        let cols = grid.column(atX: max(0, viewport.minX - Self.gutter))...grid.column(atX: max(0, viewport.maxX - Self.gutter))
        let merged = book.merges.merges(touchingRows: rows).filter { $0.end.column >= cols.lowerBound && $0.start.column <= cols.upperBound }
        ScrollView([.horizontal, .vertical]) {
            Color.white.frame(width: grid.totalWidth + Self.gutter, height: grid.totalHeight + Self.header)
                .overlay(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(rows), id: \.self) { row in
                            if grid.rowHeight(row) > 0 {
                                ForEach(Array(cols), id: \.self) { col in
                                    let address = CellAddress(row: row, column: col)
                                    if grid.columnWidth(col) > 0, book.merges.merge(containing: address) == nil {
                                        cell(CellRange(address))
                                    }
                                }
                            }
                        }
                        ForEach(merged, id: \.self) { cell($0) }
                        if let range = book.pickedRange {
                            let rect = grid.rect(of: range)
                            Rectangle().strokeBorder(.blue, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                                .frame(width: rect.width, height: rect.height)
                                .offset(x: Self.gutter + rect.minX, y: Self.header + rect.minY)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                        if picking {
                            let x = max(0, viewport.minX), y = max(0, viewport.minY)
                            FormulaTouches(addressAt: { point in
                                let address = CellAddress(row: grid.row(atY: max(0, y + point.y)),
                                                          column: grid.column(atX: max(0, x + point.x)))
                                return book.merges.merge(containing: address)?.start ?? address
                            }, pick: pickRange)
                            .frame(width: max(0, viewport.width - Self.gutter), height: max(0, viewport.height - Self.header))
                            .offset(x: x + Self.gutter, y: y + Self.header)
                            .accessibilityHidden(true)
                        }
                        ForEach(Array(cols), id: \.self) { col in
                            header(CellAddress.columnName(col), width: grid.columnWidth(col), height: Self.header)
                                .offset(x: Self.gutter + grid.x(ofColumn: col), y: max(0, viewport.minY))
                        }
                        ForEach(Array(rows), id: \.self) { row in
                            header(String(row + 1), width: Self.gutter, height: grid.rowHeight(row))
                                .offset(x: max(0, viewport.minX), y: Self.header + grid.y(ofRow: row))
                        }
                        header("", width: Self.gutter, height: Self.header)
                            .offset(x: max(0, viewport.minX), y: max(0, viewport.minY))
                    }
                    .frame(width: grid.totalWidth + Self.gutter, height: grid.totalHeight + Self.header, alignment: .topLeading)
                }
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGRect.self) { $0.visibleRect } action: { _, rect in viewport = rect }
        .background(.white)
    }

    private func header(_ text: String, width: Double, height: Double) -> some View {
        Text(verbatim: text).font(.caption.monospacedDigit()).foregroundStyle(FolioTheme.ink.color)
            .frame(width: width, height: height).background(FolioTheme.header.color)
            .border(FolioTheme.rule.color, width: 0.5).accessibilityHidden(true)
    }

    private func cell(_ range: CellRange) -> some View {
        let address = range.start
        let value = book.sheet.cells[address] ?? Cell()
        let style = book.styles.style(value.styleIndex)
        let display = CellDisplay.content(of: value, style: style, dateSystem: book.workbook.dateSystem)
        let rect = book.geometry.rect(of: range)
        let selected = book.showingEditedCell && address == book.address
        let alignment: Alignment = switch display.placement {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        }
        let color = display.color
        return Button {
            tap(address)
        } label: {
            Text(verbatim: display.text).lineLimit(1)
                .font(.system(size: 15, weight: style.font.bold ? .bold : .regular)).italic(style.font.italic)
                .foregroundStyle(Color(red: color.red, green: color.green, blue: color.blue))
                .padding(.horizontal, 5).frame(width: rect.width, height: rect.height, alignment: alignment)
                .background(style.fill.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? .white)
                .border(selected ? FolioTheme.accent.color : Color.gray.opacity(0.35), width: selected ? 2 : 0.5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier("cell-\(address.a1)")
        .accessibilityLabel(Text(verbatim: address.a1)).accessibilityValue(Text(verbatim: display.text))
        .offset(x: Self.gutter + rect.minX, y: Self.header + rect.minY)
    }
}

/// 编辑公式时在可见单元格上区分轻点、按住拖选和滚动。每个按钮各挂长按手势会吞掉普通轻点。
private struct FormulaTouches: UIViewRepresentable {
    let addressAt: (CGPoint) -> CellAddress
    let pick: (CellRange) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let handler = context.coordinator
        let hold = UILongPressGestureRecognizer(target: handler, action: #selector(Coordinator.dragged(_:)))
        hold.minimumPressDuration = 0.3
        hold.delegate = handler
        let tap = UITapGestureRecognizer(target: handler, action: #selector(Coordinator.tapped(_:)))
        tap.require(toFail: hold)
        view.addGestureRecognizer(hold)
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { context.coordinator.surface = self }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var surface: FormulaTouches
        private var anchor: CellAddress?

        init(_ surface: FormulaTouches) { self.surface = surface }

        @objc func tapped(_ tap: UITapGestureRecognizer) {
            surface.pick(CellRange(surface.addressAt(tap.location(in: tap.view))))
        }

        @objc func dragged(_ hold: UILongPressGestureRecognizer) {
            let address = surface.addressAt(hold.location(in: hold.view))
            switch hold.state {
            case .began:
                anchor = address
                surface.pick(CellRange(address))
            case .changed, .ended:
                if let anchor { surface.pick(CellRange(anchor, address)) }
                if hold.state == .ended { anchor = nil }
            default:
                anchor = nil
            }
        }

        // 手指直接移动时长按会失败，滚动便可开始；先按住则由同一次触摸完成区域选择。
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let scroll = otherGestureRecognizer.view as? UIScrollView else { return false }
            return otherGestureRecognizer === scroll.panGestureRecognizer
        }
    }
}
