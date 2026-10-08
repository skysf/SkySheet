import Foundation
import SkySheetCore
import SkySheetDisplay
import SkySheetFiles

/// 显示逻辑（设计 8.2 节）：颜色换算、样式继承、行列几何、格子显示成什么、文字溢出、选区合计。
@MainActor
func displayChecks() {
    func checkColor(_ actual: RGBAColor?, _ hex: String, _ message: String, file: StaticString = #fileID, line: UInt = #line) {
        guard let actual, let expected = RGBAColor(hex: hex) else {
            fail("\(message): got \(String(describing: actual))", file: file, line: line)
            return
        }
        // Excel 用 0–255 的整数算 HSL，和我们差 1 是正常的。
        let close = abs(actual.red - expected.red) <= 1.5 / 255 && abs(actual.green - expected.green) <= 1.5 / 255
            && abs(actual.blue - expected.blue) <= 1.5 / 255
        check(close, "\(message): got \(actual), expected \(hex)", file: file, line: line)
    }

    group("display: colors") {
        let colors = ColorResolver(themeColors: Workbook.defaultThemeColors)
        checkColor(colors.resolve(StyleColor(.theme(1)), fallback: nil), "000000", "theme 1 is dk1 (black)")
        checkColor(colors.resolve(StyleColor(.theme(0)), fallback: nil), "FFFFFF", "theme 0 is lt1 (white)")
        checkColor(colors.resolve(StyleColor(.theme(3)), fallback: nil), "44546A", "theme 3 is dk2")
        checkColor(colors.resolve(StyleColor(.theme(4)), fallback: nil), "4472C4", "theme 4 is accent1")
        checkColor(colors.resolve(StyleColor(.theme(4), tint: 0.3999755859375), fallback: nil), "8EA9DB", "accent1 lighter 40%")
        checkColor(colors.resolve(StyleColor(.theme(4), tint: -0.249977111117893), fallback: nil), "2F5597", "accent1 darker 25%")
        checkColor(colors.resolve(StyleColor(.theme(5), tint: 0.5999938962981048), fallback: nil), "F8CBAD", "accent2 lighter 60%")
        checkColor(colors.resolve(StyleColor(.rgb("FF9E1E1A")), fallback: nil), "9E1E1A", "ARGB")
        checkColor(colors.resolve(StyleColor(.indexed(10)), fallback: nil), "FF0000", "indexed 10")
        checkColor(colors.resolve(StyleColor(.indexed(64)), fallback: nil), "000000", "indexed 64 is the system foreground")
        checkEqual(colors.resolve(StyleColor(.automatic), fallback: nil), nil, "automatic falls back")
        checkColor(ColorResolver.formatColor(.named("Red")), "FF0000", "[Red]")
    }

    group("display: styles of the loan fixture") {
        let workbook = try XLSXReader.read(contentsOf: fixtureURL("loan.xlsx"))
        let styles = StyleResolver(workbook: workbook)
        let header = styles.style(7)   // A2「工行装修贷」：白字、深红底、细黑框、居中
        checkEqual(header.font.name, "等线", "font name inherited from the default font")
        checkEqual(header.font.size, 10, "font size inherited")
        checkColor(header.font.color, "FFFFFF", "white text")
        checkColor(header.fill, "9E1E1A", "dark red fill")
        checkEqual(header.left?.width, 1, "thin border")
        checkEqual(header.horizontal, .center, "centered")
        checkEqual(header.vertical, .center, "vertically centered")
        checkColor(styles.style(6).font.color, "000000", "default text is black (theme 1)")
        checkEqual(styles.style(6).fill, nil, "no fill")
        checkEqual(styles.style(9).formatCode, "0.0000%", "number format carried along")
        checkEqual(styles.style(10).formatCode, "0.00%", "builtin 68")
        checkEqual(styles.style(13).wrapText, true, "wrap text")
        checkEqual(styles.style(34).font.bold, true, "bold")
        checkEqual(styles.baseFontSize, 10, "base font size")
    }

    group("display: geometry") {
        checkEqual(SheetGeometry.columnPixels(14.9297), 105, "column A of the fixture")
        checkEqual(SheetGeometry.columnPixels(60), 420, "column N of the fixture")
        checkEqual(SheetGeometry.defaultColumnPixels(), 64, "default column, digit width 7")
        checkEqual(SheetGeometry.defaultColumnPixels(digitWidth: 8), 72, "default column, digit width 8")
        checkEqual(SheetGeometry.columnPixels(9.140625, digitWidth: 7), 64, "a 64-pixel column written by Excel")
        checkEqual(SheetGeometry.defaultRowHeight(fontSize: 11), 15, "Calibri 11")
        checkEqual(SheetGeometry.defaultRowHeight(fontSize: 10), 13.5, "等线 10")

        let axis = AxisLayout(defaultSize: 10, overrides: [2: 30, 5: 0])
        checkEqual(axis.offset(0), 0, "offset 0")
        checkEqual(axis.offset(3), 50, "after a wide cell")
        checkEqual(axis.offset(6), 70, "after a hidden cell")
        checkEqual(axis.index(at: 25, count: 100), 2, "inside the wide cell")
        checkEqual(axis.index(at: 55, count: 100), 3, "inside the cell after the wide one")
        checkEqual(axis.index(at: 70, count: 100), 6, "the hidden cell (size 0) is skipped")
        checkEqual(axis.index(at: 1e9, count: 100), 99, "beyond the end")

        var sheet = Sheet(id: 1, name: "S")
        sheet.columns = [ColumnFormat(first: 0, last: 0, width: 14.9297), ColumnFormat(first: 2, last: 3, hidden: true)]
        sheet.rowFormats = [1: RowFormat(height: 30)]
        sheet.cells[200, 5] = Cell(value: .number(1))
        let geometry = SheetGeometry(sheet: sheet, baseFontSize: 10, zoom: 2)
        checkEqual(geometry.columnWidth(0), 210, "zoomed column")
        checkEqual(geometry.columnWidth(2), 0, "hidden column")
        checkEqual(geometry.rowHeight(1), 80, "30 pt row at 200%")
        checkEqual(geometry.rowHeight(0), 36, "default 13.5 pt row at 200%")
        check(geometry.rowCount > 200 && geometry.columnCount >= 26, "scrollable extent covers the data")
        check(abs(geometry.fontPoints(10) - 10 * SheetGeometry.pixelsPerPoint * 2) < 1e-9, "font size at 200%")
    }

    group("display: what a cell shows") {
        let workbook = Workbook(styles: StyleTable(customNumberFormats: [164: "0.00;[Red]-0.00"],
                                                   cellFormats: [CellFormat(), CellFormat(numberFormatID: 164),
                                                                 CellFormat(horizontalAlignment: "center")]))
        let styles = StyleResolver(workbook: workbook)
        func show(_ value: CellValue, _ style: Int = 0) -> DisplayContent {
            CellDisplay.content(of: Cell(value: value, styleIndex: style), style: styles.style(style), dateSystem: .from1900)
        }
        checkEqual(show(.number(5)).placement, .right, "numbers go right")
        checkEqual(show(.text("x")).placement, .left, "text goes left")
        checkEqual(show(.bool(true)).placement, .center, "booleans are centered")
        checkEqual(show(.error(.div0)).placement, .center, "errors are centered")
        checkEqual(show(.number(5), 2).placement, .center, "explicit alignment wins")
        checkEqual(show(.number(-2), 1).text, "-2.00", "formatted")
        check(show(.number(-2), 1).color == RGBAColor(hex: "FF0000"), "[Red] colors the text")

        let width: (String) -> Double = { Double($0.count) * 7 }
        func fit(_ value: Decimal, _ room: Double, style: Int = 0) -> String {
            CellDisplay.fitNumber(show(.number(value), style), width: room, measure: width)
        }
        checkEqual(fit(Decimal(string: "0.0116210165161392")!, 49), "0.01162", "General drops decimals to fit")
        checkEqual(fit(Decimal(string: "0.0116210165161392")!, 200), "0.0116210165161392", "fits as it is")
        checkEqual(fit(Decimal(string: "123456789012345")!, 70), "1.2346E+14", "integer part too wide: scientific")
        checkEqual(fit(Decimal(string: "0.00000123456")!, 56), "1.23E-06", "tiny numbers go scientific, not 0.000001")
        checkEqual(fit(Decimal(string: "1234.5")!, 35, style: 1), "#####", "formatted numbers become ###")
    }

    group("display: text overflow and selection totals") {
        let widths: (Int) -> Double = { _ in 64 }
        func span(_ placement: HorizontalPlacement, empty: Set<Int>) -> ClosedRange<Int> {
            CellDisplay.overflowColumns(column: 2, textWidth: 150, placement: placement, columnWidth: widths,
                                        isEmpty: { empty.contains($0) }, columnCount: 26)
        }
        checkEqual(span(.left, empty: [3, 4, 5]), 2...4, "left text spills right")
        checkEqual(span(.left, empty: [4, 5]), 2...2, "stops at a neighbour with data")
        checkEqual(span(.right, empty: [0, 1]), 0...2, "right text spills left")
        checkEqual(span(.center, empty: [0, 1, 3, 4]), 1...3, "centered text spills both ways")

        var sheet = Sheet(id: 1, name: "csv")
        sheet.cells[0, 0] = Cell(value: .text("2025-12-01 is long"))   // 18 个字 × 7 = 126
        sheet.cells[0, 1] = Cell(value: .text("short"))
        sheet.cells[0, 2] = Cell(value: .text(String(repeating: "x", count: 200)))
        let fitted = AutoFit.columns(for: sheet, styles: StyleResolver(workbook: Workbook()), dateSystem: .from1900,
                                     digitWidth: 7, measure: { text, _ in Double(text.count) * 7 })
        checkEqual(fitted.map(\.first), [0, 2], "only columns wider than the default are widened")
        checkEqual(fitted.first?.width, 18.72, "(126 + 5) / 7, rounded up to 0.01")
        checkEqual(fitted.last?.width, 60, "capped at 60 characters")

        var cells = SparseGrid<Cell>()
        cells[0, 0] = Cell(value: .number(10))
        cells[1, 0] = Cell(value: .number(20))
        cells[2, 0] = Cell(value: .text("x"))
        let summary = SelectionSummary(cells: cells, range: CellRange(a1: "A1:A5")!)
        checkEqual(summary.count, 3, "non-empty cells")
        checkEqual(summary.numericCount, 2, "numbers")
        checkEqual(summary.sum, 30, "sum")
        checkEqual(summary.average, 15, "average")
    }
}
