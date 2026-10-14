import Foundation
import SkySheetCore
@testable import SkySheetFiles
import SkyZip

/// 哪些表能插删行列（设计第 11 条，StructureLock）：表里、或者文件别处有按位置指着它的格子、我们又读不懂的东西，就不让插删。
/// 再在能插删的表上插几行、存一遍：核对能过，没动过的部件照抄，富文本的格子挪了位置也还是原来那一条。
/// 要看写入结果里照抄了哪些部件（内部的），所以 @testable。
@MainActor
func structureLockChecks() {
    group("structure lock: which sheets can take inserted rows") {
        let loan = try XLSXReader.readDocument(try Data(contentsOf: fixtureURL("loan.xlsx")))
        checkEqual(loan.source.structureLock(forSheet: 1), .pictures, "the loan sheet has a picture")
        checkEqual(loan.source.structureLock(forSheet: 99), nil, "sheets made in SkySheet are always fine")

        let pivotRelationships = """
            <Relationships xmlns="\(packageNamespace)"><Relationship Id="rId1" \
            Type="\(relationshipNamespace)/pivotTable" Target="../pivotTables/pivotTable1.xml"/></Relationships>
            """
        let data = try makePackage(sheets: [
            ("Plain", worksheet("""
                <sheetViews><sheetView workbookViewId="0"/></sheetViews><sheetData><row r="1"><c r="A1"><v>1</v></c></row>\
                </sheetData><pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" header="0.3" footer="0.3"/>
                """), nil),
            ("Rules", worksheet("""
                <sheetData/><conditionalFormatting sqref="A1:A3"><cfRule type="cellIs" priority="1" operator="greaterThan">\
                <formula>Watched!$B$2</formula></cfRule></conditionalFormatting>
                """), nil),
            ("Watched", worksheet("<sheetData/>"), nil),
            ("Lists", worksheet("""
                <sheetData/><dataValidations count="1"><dataValidation type="list" sqref="B1"><formula1>"a,b"</formula1>\
                </dataValidation></dataValidations>
                """), nil),
            ("My Data", worksheet("<sheetData/>"), nil),
            ("Pivot", worksheet("<sheetData/>"), pivotRelationships),
            ("Breaks", worksheet("<sheetData/><rowBreaks count=\"1\" manualBreakCount=\"1\"><brk id=\"5\" man=\"1\"/></rowBreaks>"), nil),
            ("Formulas", worksheet("<sheetData><row r=\"1\"><c r=\"A1\"><f>Plain!A1*2</f><v>2</v></c></row></sheetData>"), nil),
        ], extra: [
            ("xl/charts/chart1.xml", "<c:chartSpace xmlns:c=\"urn:c\"><c:f>'My Data'!$A$1:$A$3</c:f></c:chartSpace>"),
            ("xl/pivotTables/pivotTable1.xml", "<pivotTableDefinition xmlns=\"\(mainNamespace)\"/>"),
        ])
        let source = try XLSXReader.readDocument(data).source
        checkEqual(source.structureLock(forSheet: 1), nil, "a plain sheet is fine, even with formulas elsewhere pointing at it")
        checkEqual(source.structureLock(forSheet: 2), .conditionalFormatting, "conditional formatting")
        checkEqual(source.structureLock(forSheet: 3), .referencedElsewhere("xl/worksheets/sheet2.xml"),
                   "another sheet's conditional formatting points at it")
        checkEqual(source.structureLock(forSheet: 4), .dataValidation, "a drop-down list")
        checkEqual(source.structureLock(forSheet: 5), .referencedElsewhere("xl/charts/chart1.xml"), "a chart draws its cells")
        checkEqual(source.structureLock(forSheet: 6), .otherContent("pivotTable"), "a pivot table sits on it")
        checkEqual(source.structureLock(forSheet: 7), .otherContent("rowBreaks"), "page breaks")
        checkEqual(source.structureLock(forSheet: 8), nil, "formulas are ours to rewrite")
    }

    group("structure lock: inserting rows and saving") {
        let strings = """
            <sst xmlns="\(mainNamespace)" count="2" uniqueCount="2"><si><t>plain</t></si>\
            <si><r><rPr><b/></rPr><t>Bold</t></r><r><t xml:space="preserve"> part</t></r></si></sst>
            """
        let data = try makePackage(sheets: [
            ("Data", worksheet("""
                <sheetData><row r="1"><c r="A1" t="s"><v>0</v></c></row><row r="2"><c r="A2" t="s"><v>1</v></c>\
                <c r="B2"><f>A2</f><v>0</v></c></row></sheetData>
                """), nil),
            ("Other", worksheet("<sheetData><row r=\"1\"><c r=\"A1\"><f>Data!A2</f></c></row></sheetData>"), nil),
        ], sharedStrings: strings, extra: [("xl/charts/chart1.xml", "<c:chartSpace xmlns:c=\"urn:c\"><c:f>Other!$A$1</c:f></c:chartSpace>")])
        var document = try XLSXReader.readDocument(data)
        let baseline = document.workbook
        checkEqual(document.workbook.sheets[0].richTextSources, [CellAddress(a1: "A2")!: 1], "the rich cell is noted on the sheet")
        checkEqual(document.source.structureLock(forSheet: 1), nil, "Data can take new rows")
        checkEqual(document.source.structureLock(forSheet: 2), .referencedElsewhere("xl/charts/chart1.xml"), "Other can't")

        try document.workbook.insert(1, .rows, at: 1, sheet: 0)
        Recalculator.recalculate(&document.workbook, options: RecalcOptions(today: checkToday))
        let result = try XLSXWriter.write(document.workbook, source: document.source, baseline: baseline)
        let reread = try SaveVerifier.verify(result.data, written: result, workbook: document.workbook, source: document.source)
        let cells = reread.workbook.sheets[0].cells
        checkEqual(cells[CellAddress(a1: "A3")!]?.value, .text("Bold part"), "the rich text moved down")
        checkEqual(cells[CellAddress(a1: "B3")!]?.formula?.source, "A3", "its formula moved and follows")
        checkEqual(reread.workbook.sheets[1].cells[CellAddress(a1: "A1")!]?.formula?.source, "Data!A3", "so does the other sheet")
        checkEqual(reread.workbook.sheets[0].richTextSources, [CellAddress(a1: "A3")!: 1], "still the rich string")
        let parts = try zipContents(result.data)
        let sheetXML = String(decoding: parts["xl/worksheets/sheet1.xml"] ?? Data(), as: UTF8.self)
        check(sheetXML.contains("<c r=\"A3\" t=\"s\"><v>1</v></c>"), "the moved cell points at the rich string")
        check(result.copiedEntries.contains("xl/sharedStrings.xml"), "no plain copy of it was added")
        check(result.copiedEntries.contains("xl/charts/chart1.xml"), "parts we don't read are copied as they are")
    }
}

// MARK: - 现拼一个工作簿

private let mainNamespace = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
private let relationshipNamespace = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
private let packageNamespace = "http://schemas.openxmlformats.org/package/2006/relationships"

private func worksheet(_ body: String) -> String {
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?><worksheet xmlns=\"\(mainNamespace)\" xmlns:r=\"\(relationshipNamespace)\">"
        + body + "</worksheet>"
}

/// 几张表（名字、sheet 部件、它自己的关系文件），可选的共用字符串，再加上别的部件（原样放进包里）。
private func makePackage(sheets: [(name: String, xml: String, relationships: String?)], sharedStrings: String? = nil,
                         extra: [(name: String, xml: String)] = []) throws -> Data {
    var writer = ZipWriter()
    let overrides = sheets.indices.map {
        "<Override PartName=\"/xl/worksheets/sheet\($0 + 1).xml\" "
            + "ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
    }.joined()
    try writer.addFile("[Content_Types].xml", contents: Data("""
        <?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        \(overrides)</Types>
        """.utf8))
    try writer.addFile("_rels/.rels", contents: Data("""
        <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="\(packageNamespace)">\
        <Relationship Id="rId1" Type="\(relationshipNamespace)/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """.utf8))
    let entries = sheets.enumerated().map { index, sheet in
        "<sheet name=\"\(sheet.name)\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>"
    }.joined()
    try writer.addFile("xl/workbook.xml", contents: Data("""
        <?xml version="1.0" encoding="UTF-8"?><workbook xmlns="\(mainNamespace)" xmlns:r="\(relationshipNamespace)">\
        <sheets>\(entries)</sheets></workbook>
        """.utf8))
    var relationships = sheets.indices.map {
        "<Relationship Id=\"rId\($0 + 1)\" Type=\"\(relationshipNamespace)/worksheet\" Target=\"worksheets/sheet\($0 + 1).xml\"/>"
    }.joined()
    if sharedStrings != nil {
        relationships += "<Relationship Id=\"rIdStrings\" Type=\"\(relationshipNamespace)/sharedStrings\" Target=\"sharedStrings.xml\"/>"
    }
    try writer.addFile("xl/_rels/workbook.xml.rels", contents: Data("""
        <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="\(packageNamespace)">\(relationships)</Relationships>
        """.utf8))
    if let sharedStrings { try writer.addFile("xl/sharedStrings.xml", contents: Data(sharedStrings.utf8)) }
    for (index, sheet) in sheets.enumerated() {
        try writer.addFile("xl/worksheets/sheet\(index + 1).xml", contents: Data(sheet.xml.utf8))
        if let rels = sheet.relationships {
            try writer.addFile("xl/worksheets/_rels/sheet\(index + 1).xml.rels", contents: Data(rels.utf8))
        }
    }
    for part in extra {
        try writer.addFile(part.name, contents: Data(part.xml.utf8))
    }
    return writer.finished()
}
