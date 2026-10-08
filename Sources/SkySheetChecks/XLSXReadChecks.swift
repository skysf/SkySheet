import Foundation
import SkySheetCore
import SkySheetFiles
import SkyZip

/// 读 xlsx 的边边角角（设计 7.1 节）。用 ZipWriter 现拼一个专挑刁钻写法的文件：
/// 命名空间带前缀（x:）、关系用绝对路径、共享公式、数组公式、富文本内联字符串、逻辑值、错误、1904 日期系统、没写 r 的格子。
@MainActor
func xlsxReadChecks() {
    group("xlsx: unusual but valid files") {
        let workbook = try XLSXReader.read(try unusualWorkbook())
        checkEqual(workbook.sheets.map(\.name), ["Data"], "worksheets only (the chart sheet is skipped)")
        checkEqual(workbook.dateSystem, .from1904, "date1904")
        checkEqual(workbook.definedNames.map(\.name), ["Rates"], "defined names kept")
        let sheet = workbook.sheets[0]
        checkEqual(sheet.id, 5, "sheetId")
        func cell(_ a1: String) -> Cell? { sheet.cells[CellAddress(a1: a1)!] }
        checkEqual(cell("A1")?.value, .text("你好世界"), "rich inline string, phonetic text skipped")
        checkEqual(cell("B1")?.value, .bool(true), "boolean")
        checkEqual(cell("C1")?.value, .error(.div0), "error")
        checkEqual(cell("D1")?.value, .text("next"), "cell without r follows the previous one")
        checkEqual(cell("B3")?.formula?.source, "A3*2", "shared formula follower shifted")
        checkEqual(cell("B4")?.formula?.source, "A4*2", "shared formula follower shifted")
        checkEqual(cell("B4")?.formula?.cachedValue, .number(60), "cached value kept")
        checkEqual(cell("E1")?.formula?.arrayRange, CellRange(a1: "E1:E2"), "array formula range")
        checkEqual(workbook.styles.formatCode(forStyle: cell("C2")?.styleIndex ?? 0), "0.0%", "cellXfs, not cellStyleXfs")
        checkEqual(ValueFormatter.format(cell("C2")!.value, code: "0.0%").text, "25.0%", "styled value")
        checkEqual(ValueFormatter.format(.number(0), code: "yyyy-mm-dd", dateSystem: workbook.dateSystem).text,
                   "1904-01-01", "1904 date system")

        var recalculated = workbook
        let report = Recalculator.recalculate(&recalculated, options: RecalcOptions(today: checkToday))
        checkEqual(recalculated.sheets[0].cells[CellAddress(a1: "B4")!]?.value, .number(60), "shared formula recalculates")
        let arrayCell = FormulaLocation(sheet: 0, address: CellAddress(a1: "E1")!)
        check(report.notRecalculated[arrayCell] != nil, "array formulas keep their cached value")
        checkEqual(recalculated.sheets[0].cells[arrayCell.address]?.value, .number(120), "array cached value shown")
    }

    group("xlsx: files we cannot open say why") {
        let ole: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
        let encrypted = Data(ole + Array(repeating: 0, count: 64) + "EncryptedPackage".utf16.flatMap { [UInt8($0 & 0xFF), 0] })
        do {
            _ = try XLSXReader.read(encrypted)
            fail("encrypted file accepted")
        } catch let error as XLSXError {
            checkEqual(error, .passwordProtected, "password-protected xlsx")
        }
        do {
            _ = try XLSXReader.read(Data(ole + Array(repeating: 0, count: 512)))
            fail("xls accepted")
        } catch let error as XLSXError {
            checkEqual(error, .legacyExcelFormat, "old .xls")
        }
        do {
            var writer = ZipWriter()
            try writer.addFile("hello.txt", contents: Data("not a workbook".utf8))
            _ = try XLSXReader.read(writer.finished())
            fail("zip without a workbook accepted")
        } catch let error as XLSXError {
            checkEqual(error, .missingPart("xl/workbook.xml"), "zip without a workbook")
        }
    }
}

/// 写的检查也用它：在这种文件上改完存回去，读不懂的东西（图表 sheet、x: 前缀）都要留着。
func unusualWorkbook() throws -> Data {
    let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    let pkg = "http://schemas.openxmlformats.org/package/2006/relationships"
    var writer = ZipWriter()
    try writer.addFile("[Content_Types].xml", contents: Data("""
        <?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>        <Default Extension="xml" ContentType="application/xml"/>        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>        <Override PartName="/xl/worksheets/data.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>        </Types>
        """.utf8))
    try writer.addFile("_rels/.rels", contents: Data("""
        <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="\(pkg)">\
        <Relationship Id="r1" Type="\(rel)/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """.utf8))
    try writer.addFile("xl/workbook.xml", contents: Data("""
        <?xml version="1.0" encoding="UTF-8"?><x:workbook xmlns:x="\(main)" xmlns:r="\(rel)">\
        <x:workbookPr date1904="1"/><x:sheets><x:sheet name="Chart" sheetId="9" r:id="rId9"/>\
        <x:sheet name="Data" sheetId="5" r:id="rId1"/></x:sheets>\
        <x:definedNames><x:definedName name="Rates">Data!$A$2:$A$4</x:definedName></x:definedNames></x:workbook>
        """.utf8))
    try writer.addFile("xl/_rels/workbook.xml.rels", contents: Data("""
        <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="\(pkg)">\
        <Relationship Id="rId1" Type="\(rel)/worksheet" Target="/xl/worksheets/data.xml"/>\
        <Relationship Id="rId9" Type="\(rel)/chartsheet" Target="chartsheets/sheet1.xml"/>\
        <Relationship Id="rId2" Type="\(rel)/styles" Target="styles.xml"/></Relationships>
        """.utf8))
    try writer.addFile("xl/styles.xml", contents: Data("""
        <?xml version="1.0" encoding="UTF-8"?><styleSheet xmlns="\(main)">\
        <numFmts count="1"><numFmt numFmtId="164" formatCode="0.0%"/></numFmts>\
        <cellStyleXfs count="1"><xf numFmtId="49"/></cellStyleXfs>\
        <cellXfs count="2"><xf numFmtId="0"/><xf numFmtId="164"><alignment horizontal="right"/></xf></cellXfs></styleSheet>
        """.utf8))
    try writer.addFile("xl/worksheets/data.xml", contents: Data("""
        <?xml version="1.0" encoding="UTF-8"?><x:worksheet xmlns:x="\(main)"><x:sheetData>\
        <x:row r="1"><x:c r="A1" t="inlineStr"><x:is><x:r><x:t>你好</x:t></x:r><x:r><x:t>世界</x:t></x:r>\
        <x:rPh sb="0" eb="1"><x:t>ニイハオ</x:t></x:rPh></x:is></x:c>\
        <x:c r="B1" t="b"><x:v>1</x:v></x:c><x:c r="C1" t="e"><x:v>#DIV/0!</x:v></x:c>\
        <x:c t="str"><x:v>next</x:v></x:c>\
        <x:c r="E1"><x:f t="array" ref="E1:E2">SUM(A2:A4*2)</x:f><x:v>120</x:v></x:c></x:row>\
        <x:row r="2"><x:c r="A2"><x:v>10</x:v></x:c><x:c r="B2"><x:f t="shared" ref="B2:B4" si="0">A2*2</x:f><x:v>20</x:v></x:c>\
        <x:c r="C2" s="1"><x:v>0.25</x:v></x:c></x:row>\
        <x:row r="3"><x:c r="A3"><x:v>20</x:v></x:c><x:c r="B3"><x:f t="shared" si="0"/><x:v>40</x:v></x:c></x:row>\
        <x:row r="4"><x:c r="A4"><x:v>30</x:v></x:c><x:c r="B4"><x:f t="shared" si="0"/><x:v>60</x:v></x:c></x:row>\
        </x:sheetData></x:worksheet>
        """.utf8))
    return writer.finished()
}
