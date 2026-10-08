import Foundation
import SkySheetCore
import SkySheetFiles

/// 读 csv（设计 7.3 节）：编码、分隔符、引号、值怎么转；以及读 xlsx 的字体、填充、边框、主题色。
@MainActor
func csvChecks() {
    func read(_ data: Data) throws -> CSVDocument {
        try CSVReader.read(data, sheetName: "Bank")
    }
    func value(_ document: CSVDocument, _ a1: String) -> CellValue? {
        document.workbook.sheets[0].cells[CellAddress(a1: a1)!]?.value
    }

    group("csv: encodings") {
        let text = "贷款,金额\n工行,50000\n"
        let utf8 = try read(Data(text.utf8))
        checkEqual(utf8.encoding, .utf8, "plain UTF-8")
        checkEqual(value(utf8, "A2"), .text("工行"), "UTF-8 text")
        checkEqual(utf8.workbook.sheets[0].name, "Bank", "sheet named after the file")

        let bom = try read(Data([0xEF, 0xBB, 0xBF] + Array(text.utf8)))
        check(bom.hasByteOrderMark, "UTF-8 byte order mark noticed")
        checkEqual(value(bom, "A1"), .text("贷款"), "BOM is not part of the first cell")

        let gbk = text.data(using: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))))!
        let chinese = try read(gbk)
        checkEqual(value(chinese, "A2"), .text("工行"), "GB18030 / GBK from a bank export")
        check(chinese.encoding != .utf8, "remembered as GB18030")

        let utf16 = try read(Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!)
        checkEqual(value(utf16, "B2"), .number(50000), "UTF-16 with BOM")
    }

    group("csv: delimiters and quotes") {
        checkEqual(try read(Data("a\tb\n1\t2\n".utf8)).delimiter, "\t", "tab separated")
        checkEqual(try read(Data("a;b;c\n1;2;3\n".utf8)).delimiter, ";", "semicolon separated")
        let quoted = try read(Data("名称,备注\n\"中信, 分期\",\"第一行\r\n第二行\"\n\"说\"\"好\"\"\",x\n".utf8))
        checkEqual(value(quoted, "A2"), .text("中信, 分期"), "comma inside quotes")
        checkEqual(value(quoted, "B2"), .text("第一行\r\n第二行"), "line break inside quotes")
        checkEqual(value(quoted, "A3"), .text("说\"好\""), "doubled quotes")
        checkEqual(quoted.workbook.sheets[0].cells.usedRange, CellRange(a1: "A1:B3"), "three rows, no blank row at the end")
    }

    group("csv: values") {
        let document = try read(Data("""
            00123,1234567890123456789,12.5%,2025-12-01,2025/12/1 10:30,TRUE,"1,234",-5,+3,¥100
            """.utf8))
        checkEqual(value(document, "A1"), .text("00123"), "leading zeros stay text")
        checkEqual(value(document, "B1"), .text("1234567890123456789"), "card-like numbers stay text")
        checkEqual(value(document, "C1"), .number(Decimal(string: "0.125")!), "percent")
        checkEqual(value(document, "D1"), .number(45992), "ISO date")
        checkEqual(value(document, "E1"), .number(Decimal(45992) + Decimal(37800) / 86_400), "date and time")
        checkEqual(value(document, "F1"), .bool(true), "boolean")
        checkEqual(value(document, "G1"), .text("1,234"), "thousands separators stay text")
        checkEqual(value(document, "H1"), .number(-5), "negative")
        checkEqual(value(document, "I1"), .number(3), "explicit plus")
        checkEqual(value(document, "J1"), .text("¥100"), "currency stays text")
        let styles = document.workbook.styles
        let dateCell = document.workbook.sheets[0].cells[CellAddress(a1: "D1")!]!
        checkEqual(ValueFormatter.format(dateCell.value, code: styles.formatCode(forStyle: dateCell.styleIndex)).text,
                   "2025-12-01", "dates are shown as dates")
    }

    group("xlsx: fonts, fills, borders and theme of the fixture") {
        let workbook = try XLSXReader.read(contentsOf: fixtureURL("loan.xlsx"))
        let styles = workbook.styles
        checkEqual(styles.fonts.count, 15, "fonts")
        checkEqual(styles.fonts[0], FontStyle(name: "等线", size: 10, color: StyleColor(.theme(1))), "default font")
        checkEqual(styles.fonts[9].bold, true, "<b val=\"1\"/>")
        checkEqual(styles.fonts[3].bold, false, "<b val=\"0\"/>")
        checkEqual(styles.fills[2], FillStyle(pattern: "solid", foreground: StyleColor(.rgb("FF9E1E1A"))), "solid fill")
        checkEqual(styles.borders[1].left, BorderEdge(style: "thin", color: StyleColor(.rgb("FF000000"))), "thin border")
        checkEqual(styles.borders[4].left, nil, "only a top border")
        checkEqual(styles.cellFormats.count, 116, "cellXfs")
        checkEqual(workbook.themeColors, Workbook.defaultThemeColors, "theme colors (sysClr uses lastClr)")
    }
}
