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
        checkEqual(utf8.format.encoding, .utf8, "plain UTF-8")
        checkEqual(value(utf8, "A2"), .text("工行"), "UTF-8 text")
        checkEqual(utf8.workbook.sheets[0].name, "Bank", "sheet named after the file")

        let bom = try read(Data([0xEF, 0xBB, 0xBF] + Array(text.utf8)))
        check(bom.format.hasByteOrderMark, "UTF-8 byte order mark noticed")
        checkEqual(value(bom, "A1"), .text("贷款"), "BOM is not part of the first cell")

        let gbk = text.data(using: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))))!
        let chinese = try read(gbk)
        checkEqual(value(chinese, "A2"), .text("工行"), "GB18030 / GBK from a bank export")
        check(chinese.format.encoding != .utf8, "remembered as GB18030")

        let utf16 = try read(Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!)
        checkEqual(value(utf16, "B2"), .number(50000), "UTF-16 with BOM")
    }

    group("csv: delimiters and quotes") {
        checkEqual(try read(Data("a\tb\n1\t2\n".utf8)).format.delimiter, "\t", "tab separated")
        checkEqual(try read(Data("a;b;c\n1;2;3\n".utf8)).format.delimiter, ";", "semicolon separated")
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

    group("csv: writing back keeps the file's own format") {
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let original = "日期,金额,备注\r\n2025/12/1,1234.5,\"中信, 分期\"\r\n2025-12-02 10:30,5%,\"说\"\"好\"\"\"\r\n,,\r\n"
        var document = try read(original.data(using: gb18030)!)
        checkEqual(document.format.lineEnding, "\r\n", "line ending remembered")
        document.workbook.enter(.formula("B2*2"), at: CellAddress(a1: "D2")!, sheet: 0)
        Recalculator.recalculate(&document.workbook, options: RecalcOptions(today: checkToday))
        let written = try CSVWriter.write(document.workbook.sheets[0], styles: document.workbook.styles,
                                          dateSystem: document.workbook.dateSystem, format: document.format)
        try CSVWriter.verify(written.data, written: written)
        checkEqual(String(data: written.data, encoding: gb18030),
                   "日期,金额,备注,\r\n2025-12-01,1234.5,\"中信, 分期\",2469\r\n2025-12-02 10:30:00,5%,\"说\"\"好\"\"\",\r\n",
                   "same encoding and line ending; dates, percents, formulas and quotes written the csv way")

        let tabs = try read(Data([0xEF, 0xBB, 0xBF]) + Data("a\tb\n1\t2".utf8))
        let tabsWritten = try CSVWriter.write(tabs.workbook.sheets[0], styles: tabs.workbook.styles,
                                              dateSystem: .from1900, format: tabs.format)
        checkEqual(tabsWritten.data, Data([0xEF, 0xBB, 0xBF]) + Data("a\tb\n1\t2".utf8),
                   "BOM, tabs, \\n and the missing final line break all kept")

        var sheet = Sheet(id: 1, name: "x")
        sheet.cells[0, 0] = Cell(value: .text("中"))
        do {
            _ = try CSVWriter.write(sheet, styles: StyleTable(), dateSystem: .from1900,
                                    format: CSVFormat(encoding: .ascii, hasByteOrderMark: false, delimiter: ",",
                                                      lineEnding: "\n", endsWithLineBreak: true))
            fail("unencodable text accepted")
        } catch let error as CSVWriteError {
            checkEqual(error, .unencodableCharacter("中"), "says which character can't be written")
        }
        do {
            try CSVWriter.verify(Data("a,b\n".utf8), written: tabsWritten)
            fail("a mismatching csv passed the check")
        } catch let error as CSVWriteError {
            checkEqual(error, .verificationFailed("Row 1 doesn't match after saving."), "names the row")
        }
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
