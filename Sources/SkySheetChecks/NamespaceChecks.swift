import Foundation
import SkySheetCore
import SkySheetFiles
import SkyZip

/// 读文件排查第 1 条（2026-11-16）：扫描器以前去掉前缀就认元素，扩展（别的命名空间、`extLst` 里）的同名元素能改掉
/// 已经读到的数据和设置。现在只认部件主命名空间里的元素，扩展整棵跳过、保存时原文照抄。
@MainActor
func namespaceChecks() {
    group("xlsx: an Excel 2013 extension doesn't turn a 1904 workbook back to 1900") {
        // Excel 2013 以后存的文件尾部都有这一段（x15:workbookPr chartTrackingRefBase）；以前它把日期系统改回 1900，日期差 1462 天。
        let workbook = try XLSXReader.read(try namespacedPackage(workbookBody: """
            <workbookPr date1904="1"/>\(oneSheet)<extLst>\
            <ext uri="{140A7094-0E35-4892-8432-C4D2E57EDEB5}" xmlns:x15="http://schemas.microsoft.com/office/spreadsheetml/2010/11/main">\
            <x15:workbookPr chartTrackingRefBase="1"/></ext></extLst>
            """, sheetBody: "<sheetData><row r=\"1\"><c r=\"A1\" t=\"d\"><v>2025-01-01</v></c></row></sheetData>"))
        checkEqual(workbook.dateSystem, .from1904, "the extension's workbookPr is not the workbook's")
        checkEqual(workbook.sheets[0].cells[CellAddress(a1: "A1")!]?.value, .number(44_196), "ISO dates use the 1904 serials")
    }

    group("xlsx: extension elements named like cells don't overwrite real cells") {
        let data = try namespacedPackage(sheetBody: """
            <sheetData><row r="1"><c r="A1"><v>1</v></c></row>\
            <row r="3"><c r="A3"><v>3</v><extLst><ext uri="urn:cell"><v>7</v></ext></extLst></c>\
            <c r="B3" t="inlineStr"><is><t>a</t><e:t xmlns:e="urn:test">b</e:t></is></c></row></sheetData>\
            <extLst><ext uri="urn:test"><e:c xmlns:e="urn:test" r="A1"><e:v>999</e:v></e:c></ext>\
            <ext uri="urn:main-namespace"><c r="A2"><v>5</v></c></ext></extLst>
            """)
        var document = try XLSXReader.readDocument(data)
        let cells = document.workbook.sheets[0].cells
        checkEqual(cells[CellAddress(a1: "A1")!]?.value, .number(1), "a foreign <e:c r=\"A1\"> leaves A1 alone")
        checkEqual(cells[CellAddress(a1: "A2")!], nil, "a <c> inside extLst is not a cell")
        checkEqual(cells[CellAddress(a1: "A3")!]?.value, .number(3), "a cell's own extLst doesn't replace its value")
        checkEqual(cells[CellAddress(a1: "B3")!]?.value, .text("a"), "foreign <t> isn't part of the text")

        // 改一格再存：真格子写回原来的值，扩展原文照抄，读回来（第三道保险也用这个读法）还是对的。
        let baseline = document.workbook
        document.workbook.enter(.number(2, format: nil), at: CellAddress(a1: "B1")!, sheet: 0)
        Recalculator.recalculate(&document.workbook, options: RecalcOptions(today: checkToday))
        let result = try XLSXWriter.write(document.workbook, source: document.source, baseline: baseline)
        let reread = try SaveVerifier.verify(result.data, written: result, workbook: document.workbook, source: document.source)
        checkEqual(reread.workbook.sheets[0].cells[CellAddress(a1: "A1")!]?.value, .number(1), "A1 is still 1 after saving")
        let sheetXML = String(decoding: try zipContents(result.data)["xl/worksheets/sheet1.xml"] ?? Data(), as: UTF8.self)
        check(sheetXML.contains("<c r=\"A1\"><v>1</v></c>"), "the real sheetData keeps A1 = 1")
        check(sheetXML.contains("<e:c xmlns:e=\"urn:test\" r=\"A1\"><e:v>999</e:v></e:c>"), "the extension is kept as it was")
    }

    group("xlsx: attributes in other namespaces don't stand in for real ones") {
        // 没有前缀的属性不在任何命名空间里：别的命名空间里同名的属性既不能盖掉它，也不能在它不在的时候冒充它。
        let filled = try XLSXReader.read(try namespacedPackage(
            workbookBody: "<workbookPr e:date1904=\"1\" xmlns:e=\"urn:e\"/>" + oneSheet))
        checkEqual(filled.dateSystem, .from1900, "e:date1904 is not date1904")
        let both = try XLSXReader.read(try namespacedPackage(
            workbookBody: "<workbookPr date1904=\"1\" e:date1904=\"0\" xmlns:e=\"urn:e\"/>"
                + "<sheets><sheet name=\"Data\" sheetId=\"1\" r:id=\"rId1\" e:id=\"rId9\" e:name=\"Evil\" xmlns:e=\"urn:e\"/></sheets>"))
        checkEqual(both.dateSystem, .from1904, "the real date1904 wins")
        checkEqual(both.sheets.map(\.name), ["Data"], "the real name and relationship id win")
    }

    group("xlsx: a workbook written the way Excel does reads and saves as before") {
        // 和 main 对照（这一组在修之前、修之后都得过）：Excel 2016 以后的文件到处是别的命名空间里的元素和属性
        // （mc:、xr:、x14ac:dyDescent、x14 的 extLst），改成按命名空间认以后，读出来的东西一样不能变。
        let (workbook, source) = try openForEditing(try excelStyleWorkbook())
        checkEqual(workbook.dateSystem, .from1900, "date system")
        checkEqual(workbook.sheets.map(\.name), ["Data", "Other"], "sheets")
        checkEqual(workbook.sheets.map(\.visibility), [.visible, .hidden], "visibility")
        check(workbook.sheets[1].role.isAI, "custom.xml (vt:lpwstr) marks Other as AI's")
        checkEqual(workbook.definedNames.map(\.name), ["_xlnm._FilterDatabase", "Rate"], "defined names")
        checkEqual(workbook.definedNames.map(\.sheetIndex), [0, nil], "their scope")
        checkEqual(workbook.definedNames.map(\.extraAttributes), [["hidden": "1"], ["comment": "c", "uid": "{ABC}"]],
                   "their other attributes")
        checkEqual(workbook.styles.customNumberFormats[164], "0.0%", "number format")
        checkEqual(workbook.styles.fonts.map(\.bold), [nil, true], "fonts (the dxf fonts don't count)")
        checkEqual(workbook.styles.cellFormats.map(\.horizontalAlignment), [nil, "center"], "cell formats")
        let sheet = workbook.sheets[0]
        func cell(_ a1: String) -> Cell? { sheet.cells[CellAddress(a1: a1)!] }
        checkEqual(sheet.tabColor, "FF00B050", "tab color")
        checkEqual(sheet.frozen, FrozenPanes(rows: 1, columns: 1), "frozen panes")
        checkEqual(sheet.columns, [ColumnFormat(first: 0, last: 0, width: 12.5),
                                   ColumnFormat(first: 2, last: 3, width: 9, hidden: true)], "columns")
        checkEqual(sheet.rowFormats[0]?.height, 20, "row height")
        checkEqual(sheet.rowFormats[3]?.hidden, true, "hidden row")
        checkEqual(sheet.merges, [CellRange(a1: "E5:F5")!], "merged cells")
        checkEqual(sheet.defaultRowHeight, 15, "default row height")
        checkEqual(cell("A1")?.value, .text("Amount"), "shared string")
        checkEqual(cell("C1")?.value, .text("Rich text\r"), "rich shared string")
        checkEqual(sheet.richTextSources, [CellAddress(a1: "C1")!: 1], "the rich string is noted")
        checkEqual(cell("F1")?.value, .text("甲 乙"), "inline rich text without the phonetic guide")
        checkEqual(cell("B2")?.formula?.source, "A2*$B$1", "formula")
        checkEqual(cell("C3")?.formula?.source, "A3+B3", "shared formula follower")
        checkEqual(cell("C4")?.value, .number(315), "recalculated")
        checkEqual(cell("D2")?.formula?.arrayRange, CellRange(a1: "D2:D3"), "array formula")
        checkEqual(cell("E2")?.value, .bool(true), "boolean")
        checkEqual(cell("F2")?.value, .error(CellError(code: "#N/A")), "error")
        checkEqual(cell("E3")?.value, .text("x200"), "text formula")
        checkEqual(cell("E4")?.value, .number(Decimal(string: "45658.5")!), "ISO date with a time")
        checkEqual(cell("B5")?.value, .number(7), "reference to the other sheet")

        var edited = workbook
        edited.enter(.number(42, format: nil), at: CellAddress(a1: "K10")!, sheet: 0)
        Recalculator.recalculate(&edited, options: RecalcOptions(today: checkToday))
        let (result, reread) = try save(edited, source: source, baseline: workbook)
        checkEqual(reread.workbook.sheets[0].cells[CellAddress(a1: "C3")!]?.formula?.source, "A3+B3", "saved and read back")
        check(result.copiedEntries.contains("xl/worksheets/sheet2.xml"), "the other sheet is copied")
        let xml = String(decoding: try zipContents(result.data)["xl/worksheets/sheet1.xml"] ?? Data(), as: UTF8.self)
        check(xml.contains("<x14:conditionalFormattings>") && xml.contains("<xm:sqref>A2:A4</xm:sqref>"), "the extension is kept")
    }

    group("xlsx: other main namespaces still read") {
        // 主命名空间按根元素认：严格版的文件、根本没写命名空间的文件都和以前一样读。
        let strict = try XLSXReader.read(try namespacedPackage(
            main: "http://purl.oclc.org/ooxml/spreadsheetml/main",
            relationships: "http://purl.oclc.org/ooxml/officeDocument/relationships",
            workbookBody: "<workbookPr date1904=\"1\"/>" + oneSheet,
            sheetBody: "<sheetData><row r=\"1\"><c r=\"A1\"><v>5</v></c></row></sheetData>"))
        checkEqual(strict.sheets.map(\.name), ["Data"], "Strict Open XML")
        checkEqual(strict.dateSystem, .from1904, "Strict workbookPr")
        checkEqual(strict.sheets.first?.cells[CellAddress(a1: "A1")!]?.value, .number(5), "Strict cells")
        let bare = try XLSXReader.read(try namespacedPackage(
            main: nil, workbookBody: oneSheet, sheetBody: "<sheetData><row r=\"1\"><c r=\"A1\"><v>6</v></c></row></sheetData>"))
        checkEqual(bare.sheets.first?.cells[CellAddress(a1: "A1")!]?.value, .number(6), "no namespace at all")
    }
}

/// workbook.xml 里只有一张 Data。
let oneSheet = "<sheets><sheet name=\"Data\" sheetId=\"1\" r:id=\"rId1\"/></sheets>"

/// 现拼一个一张表的 xlsx：workbook.xml、sheet1.xml 的根元素在 `main` 命名空间里（nil 就不写），正文由调用方给。
/// 关系类型按 `relationships` 那一版写（严格版的类型也在那个命名空间下面）。
func namespacedPackage(main: String? = "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
                       relationships: String = "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
                       workbookBody: String = oneSheet, sheetBody: String = "<sheetData/>") throws -> Data {
    let package = "http://schemas.openxmlformats.org/package/2006/relationships"
    let namespaces = (main.map { " xmlns=\"\($0)\"" } ?? "") + " xmlns:r=\"\(relationships)\""
    var writer = ZipWriter()
    try writer.addFile("[Content_Types].xml", contents: Data("""
        <?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
        </Types>
        """.utf8))
    try writer.addFile("_rels/.rels", contents: Data("""
        <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="\(package)">\
        <Relationship Id="rId1" Type="\(relationships)/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """.utf8))
    try writer.addFile("xl/workbook.xml", contents: Data("""
        <?xml version="1.0" encoding="UTF-8"?><workbook\(namespaces)>\(workbookBody)</workbook>
        """.utf8))
    try writer.addFile("xl/_rels/workbook.xml.rels", contents: Data("""
        <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="\(package)">\
        <Relationship Id="rId1" Type="\(relationships)/worksheet" Target="worksheets/sheet1.xml"/></Relationships>
        """.utf8))
    try writer.addFile("xl/worksheets/sheet1.xml", contents: Data("""
        <?xml version="1.0" encoding="UTF-8"?><worksheet\(namespaces)>\(sheetBody)</worksheet>
        """.utf8))
    return writer.finished()
}

/// Excel 2016 以后存的样子（内容是编的）：两张表（Other 藏着，custom.xml 里记着是 AI 的），共享公式、数组公式、富文本、
/// 注音、条件格式，各部件都带着 mc:、xr:、x14ac: 这些别的命名空间里的元素和属性，workbook、sheet、styles 尾部都有 extLst。
func excelStyleWorkbook() throws -> Data {
    let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    let pkg = "http://schemas.openxmlformats.org/package/2006/relationships"
    let mc = "http://schemas.openxmlformats.org/markup-compatibility/2006"
    let x14ac = "http://schemas.microsoft.com/office/spreadsheetml/2009/9/ac"
    let x14 = "http://schemas.microsoft.com/office/spreadsheetml/2009/9/main"
    let x15 = "http://schemas.microsoft.com/office/spreadsheetml/2010/11/main"
    let xr = "http://schemas.microsoft.com/office/spreadsheetml/2014/revision"
    let xr2 = "http://schemas.microsoft.com/office/spreadsheetml/2015/revision2"
    let sheetType = "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"
    var writer = ZipWriter()
    func add(_ name: String, _ text: String) throws { try writer.addFile(name, contents: Data(text.utf8)) }
    try add("[Content_Types].xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="\(sheetType)"/>\
        <Override PartName="/xl/worksheets/sheet2.xml" ContentType="\(sheetType)"/>\
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
        <Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>\
        <Override PartName="/docProps/custom.xml" ContentType="application/vnd.openxmlformats-officedocument.custom-properties+xml"/>\
        </Types>
        """)
    try add("_rels/.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="\(pkg)">\
        <Relationship Id="rId1" Type="\(rel)/officeDocument" Target="xl/workbook.xml"/>\
        <Relationship Id="rId4" Type="\(rel)/custom-properties" Target="docProps/custom.xml"/></Relationships>
        """)
    try add("xl/workbook.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
        <workbook xmlns="\(main)" xmlns:r="\(rel)" xmlns:mc="\(mc)" mc:Ignorable="x15 xr xr2" xmlns:x15="\(x15)" \
        xmlns:xr="\(xr)" xmlns:xr2="\(xr2)">\
        <fileVersion appName="xl" lastEdited="7" lowestEdited="7" rupBuild="27425"/>\
        <workbookPr defaultThemeVersion="166925"/>\
        <mc:AlternateContent xmlns:mc="\(mc)"><mc:Choice Requires="x15">\
        <x15ac:absPath url="/Users/someone/" xmlns:x15ac="http://schemas.microsoft.com/office/spreadsheetml/2010/11/ac"/>\
        </mc:Choice></mc:AlternateContent>\
        <xr:revisionPtr revIDLastSave="0" documentId="8_{1}" xr6:coauthVersionLast="47" \
        xmlns:xr6="http://schemas.microsoft.com/office/spreadsheetml/2016/revision6"/>\
        <bookViews><workbookView xWindow="0" yWindow="500" windowWidth="28800" windowHeight="16200" \
        xr2:uid="{00000000-000D-0000-FFFF-FFFF00000000}"/></bookViews>\
        <sheets><sheet name="Data" sheetId="1" r:id="rId1"/><sheet name="Other" sheetId="2" state="hidden" r:id="rId2"/></sheets>\
        <definedNames><definedName name="_xlnm._FilterDatabase" localSheetId="0" hidden="1">Data!$A$1:$B$3</definedName>\
        <definedName name="Rate" comment="c" xr:uid="{ABC}">Data!$B$1</definedName></definedNames>\
        <calcPr calcId="191029"/>\
        <extLst><ext uri="{140A7094-0E35-4892-8432-C4D2E57EDEB5}" xmlns:x15="\(x15)">\
        <x15:workbookPr chartTrackingRefBase="1"/></ext></extLst></workbook>
        """)
    try add("xl/_rels/workbook.xml.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="\(pkg)">\
        <Relationship Id="rId1" Type="\(rel)/worksheet" Target="worksheets/sheet1.xml"/>\
        <Relationship Id="rId2" Type="\(rel)/worksheet" Target="worksheets/sheet2.xml"/>\
        <Relationship Id="rId3" Type="\(rel)/styles" Target="styles.xml"/>\
        <Relationship Id="rId5" Type="\(rel)/sharedStrings" Target="sharedStrings.xml"/></Relationships>
        """)
    try add("xl/worksheets/sheet1.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
        <worksheet xmlns="\(main)" xmlns:r="\(rel)" xmlns:mc="\(mc)" mc:Ignorable="x14ac xr xr2" xmlns:x14ac="\(x14ac)" \
        xmlns:xr="\(xr)" xmlns:xr2="\(xr2)" xr:uid="{00000000-0001-0000-0000-000000000000}">\
        <sheetPr><tabColor rgb="FF00B050"/></sheetPr><dimension ref="A1:F5"/>\
        <sheetViews><sheetView tabSelected="1" workbookViewId="0" xr2:uid="{1}">\
        <pane xSplit="1" ySplit="1" topLeftCell="B2" activePane="bottomRight" state="frozen"/>\
        <selection pane="bottomRight" activeCell="B2" sqref="B2"/></sheetView></sheetViews>\
        <sheetFormatPr defaultRowHeight="15" x14ac:dyDescent="0.25"/>\
        <cols><col min="1" max="1" width="12.5" customWidth="1"/><col min="3" max="4" width="9" hidden="1" customWidth="1"/></cols>\
        <sheetData>\
        <row r="1" spans="1:6" ht="20" customHeight="1" x14ac:dyDescent="0.25"><c r="A1" t="s"><v>0</v></c>\
        <c r="B1" s="1"><v>0.05</v></c><c r="C1" t="s"><v>1</v></c><c r="F1" t="inlineStr"><is><r><rPr><b/></rPr><t>甲</t></r>\
        <r><t xml:space="preserve"> 乙</t></r><rPh sb="0" eb="1"><t>コウ</t></rPh></is></c></row>\
        <row r="2" spans="1:6" x14ac:dyDescent="0.25"><c r="A2"><v>100</v></c><c r="B2"><f>A2*$B$1</f><v>5</v></c>\
        <c r="C2"><f t="shared" ref="C2:C4" si="0">A2+B2</f><v>105</v></c><c r="D2"><f t="array" ref="D2:D3">A2:A3*2</f><v>200</v></c>\
        <c r="E2" t="b"><v>1</v></c><c r="F2" t="e"><v>#N/A</v></c></row>\
        <row r="3" spans="1:6" x14ac:dyDescent="0.25"><c r="A3"><v>200</v></c><c r="B3"><f>A3*$B$1</f><v>10</v></c>\
        <c r="C3"><f t="shared" si="0"/><v>210</v></c><c r="D3"><v>400</v></c>\
        <c r="E3" t="str"><f>"x"&amp;A3</f><v>x200</v></c></row>\
        <row r="4" spans="1:6" hidden="1" x14ac:dyDescent="0.25"><c r="A4"><v>300</v></c><c r="B4"><f>A4*$B$1</f><v>15</v></c>\
        <c r="C4"><f t="shared" si="0"/><v>315</v></c><c r="E4" t="d"><v>2025-01-01T12:00:00</v></c></row>\
        <row r="5" spans="1:6" x14ac:dyDescent="0.25"><c r="A5"><f>SUM(A2:A4)</f><v>600</v></c><c r="B5"><f>Other!A1</f><v>7</v></c></row>\
        </sheetData>\
        <mergeCells count="1"><mergeCell ref="E5:F5"/></mergeCells>\
        <conditionalFormatting sqref="A2:A4"><cfRule type="cellIs" dxfId="0" priority="1" operator="greaterThan">\
        <formula>150</formula></cfRule></conditionalFormatting>\
        <pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" header="0.3" footer="0.3"/>\
        <extLst><ext uri="{78C0D931-6437-407d-A8EE-F0AAD7539E65}" xmlns:x14="\(x14)"><x14:conditionalFormattings>\
        <x14:conditionalFormatting xmlns:xm="http://schemas.microsoft.com/office/excel/2006/main">\
        <x14:cfRule type="dataBar" id="{1}"><x14:dataBar minLength="0" maxLength="100"><x14:cfvo type="autoMin"/>\
        <x14:cfvo type="autoMax"/></x14:dataBar></x14:cfRule><xm:sqref>A2:A4</xm:sqref></x14:conditionalFormatting>\
        </x14:conditionalFormattings></ext></extLst></worksheet>
        """)
    try add("xl/worksheets/sheet2.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="\(main)" xmlns:r="\(rel)">\
        <sheetData><row r="1"><c r="A1"><v>7</v></c></row></sheetData></worksheet>
        """)
    try add("xl/sharedStrings.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><sst xmlns="\(main)" count="2" uniqueCount="2">\
        <si><t>Amount</t></si><si><r><rPr><b/><sz val="11"/></rPr><t>Rich</t></r><r><t xml:space="preserve"> text_x000D_</t></r>\
        <rPh sb="0" eb="1"><t>リッチ</t></rPh><phoneticPr fontId="1"/></si></sst>
        """)
    try add("xl/styles.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
        <styleSheet xmlns="\(main)" xmlns:mc="\(mc)" mc:Ignorable="x14ac" xmlns:x14ac="\(x14ac)">\
        <numFmts count="1"><numFmt numFmtId="164" formatCode="0.0%"/></numFmts>\
        <fonts count="2" x14ac:knownFonts="1"><font><sz val="11"/><color theme="1"/><name val="Calibri"/><family val="2"/>\
        <scheme val="minor"/></font><font><b/><sz val="11"/><color rgb="FFFF0000"/><name val="Calibri"/></font></fonts>\
        <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
        <cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>\
        <xf numFmtId="164" fontId="1" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"><alignment horizontal="center"/></xf>\
        </cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>\
        <dxfs count="1"><dxf><font><color rgb="FF9C0006"/></font><fill><patternFill><bgColor rgb="FFFFC7CE"/></patternFill></fill></dxf></dxfs>\
        <tableStyles count="0" defaultTableStyle="TableStyleMedium2" defaultPivotStyle="PivotStyleLight16"/>\
        <extLst><ext uri="{EB79DEF2-80B8-43e5-95BD-54CBDDF9020C}" xmlns:x14="\(x14)">\
        <x14:slicerStyles defaultSlicerStyle="SlicerStyleLight1"/></ext>\
        <ext uri="{46F421CA-312F-682f-3DD2-61675219B42D}" xmlns:x14="\(x14)"><x14:dxfs count="1"><dxf><font><b/></font></dxf>\
        </x14:dxfs></ext></extLst></styleSheet>
        """)
    try add("docProps/custom.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/custom-properties" \
        xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">\
        <property fmtid="{D5CDD505-2E9C-101B-9397-08002B2CF9AE}" pid="2" name="Owner"><vt:lpwstr>Finance</vt:lpwstr></property>\
        <property fmtid="{D5CDD505-2E9C-101B-9397-08002B2CF9AE}" pid="3" name="SkySheet.AI.2">\
        <vt:lpwstr>{"c":"claude-code","t":"2026-10-08T06:03:00Z"}</vt:lpwstr></property></Properties>
        """)
    return writer.finished()
}
