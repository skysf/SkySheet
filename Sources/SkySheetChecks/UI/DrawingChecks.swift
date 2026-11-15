import AppKit
import SkySheetCore
import SkySheetDisplay
@testable import SkySheet

@MainActor
func renderRegion(_ canvas: SheetCanvas, rows: Range<Int>, columns: Range<Int>, clip: CGRect) -> NSBitmapImageRep {
    renderPixels(width: 700, height: 400) {
        clip.clip()
        RegionRenderer(canvas: canvas, geometry: canvas.geometry, rows: rows, columns: columns, visibleRows: rows, visibleColumns: columns,
                       paneColumns: columns, reach: clip, clip: clip).draw(selection: nil)
    }
}

@MainActor
func mergedPaneBorderChecks() {
    group("ui-11: visible merged borders without anchor in pane") {
        let black = BorderEdge(style: "thin", color: StyleColor(.rgb("000000")))
        let table = StyleTable(cellFormats: [CellFormat(borderID: 1)],
                              borders: [BorderStyle(), BorderStyle(left: black, right: black, top: black, bottom: black)])
        for (merge, rows, columns) in [("A1:C1", 0..<1, 1..<4), ("A1:A4", 1..<5, 0..<1), ("A1:C4", 1..<5, 1..<4)] {
            var sheet = Sheet(id: 1, name: "Merge")
            sheet.merges = [CellRange(a1: merge)!]
            sheet.cells[CellAddress(a1: "A1")!] = Cell(value: .empty)
            sheet.frozen = FrozenPanes(rows: rows.lowerBound, columns: columns.lowerBound)
            let canvas = SheetCanvas(session: SheetSession(workbook: Workbook(sheets: [sheet], styles: table)), fonts: FontBook())
            let rect = canvas.rect(of: sheet.merges[0])
            let clip = CGRect(x: canvas.geometry.x(ofColumn: columns.lowerBound), y: canvas.geometry.y(ofRow: rows.lowerBound),
                              width: 600, height: 300)
            let bitmap = renderRegion(canvas, rows: rows, columns: columns, clip: clip)
            let point = CGPoint(x: rect.maxX - 1, y: max(rect.minY + 5, clip.minY + 5))
            check(luminance(bitmap.colorAt(x: Int(point.x), y: Int(point.y))!) < 0.1, "\(merge) right edge survives pane/scroll clipping")
        }
    }
}

@MainActor
func redPixels(_ bitmap: NSBitmapImageRep) -> [Int] {
    var pixels: [Int] = []
    for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
        let c = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
        if c.redComponent > c.greenComponent + 0.15, c.redComponent > c.blueComponent + 0.15 { pixels.append(y * bitmap.pixelsWide + x) }
    } }
    return pixels
}

@MainActor
func centeredOverflowChecks() {
    group("ui-12: centered overflow remains anchored to source cell") {
        let table = StyleTable(cellFormats: [CellFormat(horizontalAlignment: "center"), CellFormat(fontID: 1)],
                              fonts: [FontStyle(name: "Helvetica", size: 11, color: StyleColor(.rgb("FF0000"))), FontStyle(color: StyleColor(.rgb("000000")))])
        for mode in 0..<4 {
            var sheet = Sheet(id: 1, name: "Center")
            let address = CellAddress(row: 1, column: mode == 0 ? 0 : 2)
            let cell = Cell(value: .text("MMMMMMMMMMMM"))
            sheet.cells[address] = cell
            sheet.defaultColumnWidth = 5
            if mode == 2 { sheet.cells[CellAddress(row: 1, column: 1)] = Cell(value: .number(1), styleIndex: 1) }
            if mode == 3 { sheet.columns = [ColumnFormat(first: 1, last: 1, width: 15)] }
            let canvas = SheetCanvas(session: SheetSession(workbook: Workbook(sheets: [sheet], styles: table)), fonts: FontBook())
            let rect = canvas.rect(of: CellRange(address))
            let (content, style) = canvas.content(of: cell)
            let attrs = canvas.textAttributes(cell, style: style, content: content)
            let size = attrs.size(of: content.text)
            let span = CellDisplay.overflowColumns(column: address.column, textWidth: size.width + 4, placement: .center,
                columnWidth: { canvas.geometry.columnWidth($0) }, isEmpty: { canvas.isEmpty(row: 1, column: $0) }, columnCount: 20)
            let area = canvas.rect(of: CellRange(CellAddress(row: 1, column: span.lowerBound), CellAddress(row: 1, column: span.upperBound)))
            let actual = renderRegion(canvas, rows: 0..<10, columns: 0..<20, clip: CGRect(x: 0, y: 0, width: 700, height: 400))
            let expected = renderPixels(width: 700, height: 400) {
                NSColor.white.setFill(); CGRect(x: 0, y: 0, width: 700, height: 400).fill()
                area.clip()
                attrs.line(content.text).draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.maxY - size.height - 1))
            }
            // 只比红字，网格线和左边阻挡的黑色数字不参与字形锚点断言。
            let actualRed = redPixels(actual)
            let expectedRed = redPixels(expected)
            check(!expectedRed.isEmpty, "reference text has pixels")
            check(actualRed == expectedRed, "centered layout \(mode) matches original-cell anchor (\(actualRed.count)/\(expectedRed.count) red pixels)")
        }
    }
}

@MainActor
func cursorExtentChecks() async {
    group("ui-13: active cursor outside used extent") {}
    let session = SheetSession(workbook: Workbook(sheets: [Sheet(id: 1, name: "Main")]))
    let view = SpreadsheetView(session: session)
    let controller = NSViewController()
    controller.view = view
    let window = OffscreenWindow.make(controller, size: CGSize(width: 800, height: 500))
    window.layoutIfNeeded()
    view.layoutSubtreeIfNeeded()
    for a1 in ["AA1", "A101", "AZ201", "B2"] {
        session.select(CellAddress(a1: a1)!)
        // 观察回调和后台窗口的首次布局都异步排队；CI 不保证 10 ms 内完成，等实际结果而非固定延时。
        // 不在自检里调用 scrollToCursor，旧版没有扩画布仍会超时失败，不能靠测试补上生产行为。
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        repeat {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
            window.layoutIfNeeded()
            view.layoutSubtreeIfNeeded()
            if let canvas = view.canvas {
                let cursor = session.selection.cursor
                let rect = canvas.rect(of: CellRange(cursor)).offsetBy(dx: -canvas.frozenWidth, dy: -canvas.frozenHeight)
                if canvas.geometry.columnCount > cursor.column, canvas.geometry.rowCount > cursor.row,
                   view.mainPane.visibleRect.contains(rect) { break }
            }
        } while clock.now < deadline
        let cursor = session.selection.cursor
        let canvas = view.canvas!
        check(canvas.geometry.columnCount > cursor.column, "\(a1) canvas contains cursor column")
        check(canvas.geometry.rowCount > cursor.row, "\(a1) canvas contains cursor row")
        let rect = canvas.rect(of: CellRange(cursor)).offsetBy(dx: -canvas.frozenWidth, dy: -canvas.frozenHeight)
        check(view.mainPane.visibleRect.contains(rect), "\(a1) is visible after observation and layout; cell=\(rect), visible=\(view.mainPane.visibleRect), view=\(view.bounds), scroll=\(view.scrollView.contentView.bounds)")
    }
    check(!window.isVisible, "UI checks never order a window on screen")
}
