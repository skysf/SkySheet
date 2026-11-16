import AppKit
import SkySheetCore
import SkySheetDisplay
import SkySheetFiles
import SkyZip

// 用最小 xlsx 走真实读取入口，不能只测已经构造好的安全模型。
func colorWorkbook(fontColor: String = "", format: String = "0") throws -> Workbook {
    let ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    let pkg = "http://schemas.openxmlformats.org/package/2006/relationships"
    var zip = ZipWriter()
    let parts = [
        "[Content_Types].xml": "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"/>",
        "_rels/.rels": "<Relationships xmlns=\"\(pkg)\"><Relationship Id=\"r1\" Type=\"\(rel)/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>",
        "xl/workbook.xml": "<workbook xmlns=\"\(ns)\" xmlns:r=\"\(rel)\"><sheets><sheet name=\"Colors\" sheetId=\"1\" r:id=\"r1\"/></sheets></workbook>",
        "xl/_rels/workbook.xml.rels": "<Relationships xmlns=\"\(pkg)\"><Relationship Id=\"r1\" Type=\"\(rel)/worksheet\" Target=\"worksheets/sheet1.xml\"/><Relationship Id=\"r2\" Type=\"\(rel)/styles\" Target=\"styles.xml\"/></Relationships>",
        "xl/styles.xml": "<styleSheet xmlns=\"\(ns)\"><numFmts count=\"1\"><numFmt numFmtId=\"164\" formatCode=\"\(format)\"/></numFmts><fonts count=\"1\"><font><sz val=\"11\"/>\(fontColor)</font></fonts><cellXfs count=\"1\"><xf numFmtId=\"164\" fontId=\"0\"/></cellXfs></styleSheet>",
        "xl/worksheets/sheet1.xml": "<worksheet xmlns=\"\(ns)\"><sheetData><row r=\"1\"><c r=\"A1\"><v>1</v></c></row></sheetData></worksheet>"]
    for (name, xml) in parts { try zip.addFile(name, contents: Data(xml.utf8)) }
    return try XLSXReader.read(zip.finished())
}

@MainActor
func invalidThemeChecks() {
    group("ui-6a: invalid theme and palette indices") {
        let workbook = try colorWorkbook(fontColor: "<color theme=\"-1\"/>")
        checkEqual(StyleResolver(workbook: workbook).style(0).font.color, .black, "negative theme in xlsx falls back")
        let colors = ColorResolver(themeColors: Workbook.defaultThemeColors)
        for index in [Int.min, -1, 12, Int.max] {
            checkEqual(colors.resolve(StyleColor(.theme(index)), fallback: .black), .black, "invalid theme \(index)")
        }
        for value in ["9223372036854775808", "-9223372036854775809"] {
            let oversized = try colorWorkbook(fontColor: "<color theme=\"\(value)\"/>")
            checkEqual(StyleResolver(workbook: oversized).style(0).font.color, .black, "unrepresentable theme index")
        }
        for index in [Int.min, -1, 66, Int.max] {
            checkEqual(colors.resolve(StyleColor(.indexed(index)), fallback: .black), .black, "invalid palette \(index)")
        }
    }
}

@MainActor
func invalidFormatColorChecks() {
    group("ui-6b: overflowing format color") {
        let workbook = try colorWorkbook(format: "[Color9223372036854775807]0")
        let style = StyleResolver(workbook: workbook).style(0)
        let cell = workbook.sheets[0].cells[CellAddress(a1: "A1")!]!
        checkEqual(CellDisplay.content(of: cell, style: style, dateSystem: workbook.dateSystem).color, .black, "overflowing color in xlsx falls back")
        for index in [Int.min, -1, 0, 57, Int.max] {
            checkEqual(ColorResolver.formatColor(.indexed(index)), nil, "invalid format palette \(index)")
        }
        checkEqual(ColorResolver.formatColor(.indexed(1)), .black, "valid first color")
        check(ColorResolver.formatColor(.indexed(56)) != nil, "valid last color")
        let oversized = try colorWorkbook(format: "[Color9223372036854775808]0")
        let oversizedStyle = StyleResolver(workbook: oversized).style(0)
        checkEqual(CellDisplay.content(of: cell, style: oversizedStyle, dateSystem: oversized.dateSystem).color, .black,
                   "unrepresentable format color falls back")
    }
}

func luminance(_ color: NSColor) -> Double {
    let color = color.usingColorSpace(.sRGB)!
    func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
    return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
}

func opaque(_ color: NSColor, over background: NSColor) -> NSColor {
    let fg = color.usingColorSpace(.sRGB)!
    let bg = background.usingColorSpace(.sRGB)!
    let alpha = fg.alphaComponent
    return NSColor(srgbRed: fg.redComponent * alpha + bg.redComponent * (1 - alpha),
                   green: fg.greenComponent * alpha + bg.greenComponent * (1 - alpha),
                   blue: fg.blueComponent * alpha + bg.blueComponent * (1 - alpha), alpha: 1)
}

@MainActor
func headerContrast(_ bitmap: NSBitmapImageRep, x: Int) -> Double {
    var darkest = 1.0
    var brightest = 0.0
    for row in 3..<18 { for column in (x - 6)...(x + 6) {
        let value = luminance(bitmap.colorAt(x: column, y: row)!)
        darkest = min(darkest, value)
        brightest = max(brightest, value)
    } }
    let background = luminance(bitmap.colorAt(x: x + 20, y: 5)!)
    return max((background + 0.05) / (darkest + 0.05), (brightest + 0.05) / (background + 0.05))
}

@MainActor
func chromeContrastChecks() {
    group("ui-9: chrome contrast in Aqua and Dark Aqua") {
        let session = SheetSession(workbook: Workbook(sheets: [Sheet(id: 1, name: "Main")]))
        let grid = SpreadsheetView(session: session)
        grid.frame = CGRect(x: 0, y: 0, width: 600, height: 300)
        grid.layoutSubtreeIfNeeded()
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = NSAppearance(named: name)!
            grid.appearance = appearance
            appearance.performAsCurrentDrawingAppearance {
                let label = grid.sizeLabel
                let backgroundColor = opaque(label.backgroundColor!, over: .white)
                let fg = luminance(opaque(label.textColor!, over: backgroundColor))
                let bg = luminance(backgroundColor)
                let sizeContrast = (max(fg, bg) + 0.05) / (min(fg, bg) + 0.05)
                check(sizeContrast >= 4.5, "size hint contrast \(name)")
                let header = grid.columnHeader
                let bitmap = renderPixels(width: 600, height: 22) { header.draw(header.bounds) }
                let x = Int(grid.canvas!.geometry.x(ofColumn: 1) + grid.canvas!.geometry.columnWidth(1) / 2)
                let contrast = headerContrast(bitmap, x: x)
                check(contrast >= (name == .darkAqua ? 4.5 : 3), "header label contrast \(name): \(contrast)")
                print(String(format: "chrome contrast %@: header %.2f, size hint %.2f", name.rawValue, contrast, sizeContrast))
                if name == .darkAqua {
                    session.selectLines(.columns, through: 1, extend: false, crossIndex: 0)
                    let selected = renderPixels(width: 600, height: 22) { header.draw(header.bounds) }
                    let selectedContrast = headerContrast(selected, x: x)
                    check(selectedContrast >= 4.5, "selected dark header contrast: \(selectedContrast)")
                    print(String(format: "chrome contrast selected dark header: %.2f", selectedContrast))
                }
            }
        }
    }
}
