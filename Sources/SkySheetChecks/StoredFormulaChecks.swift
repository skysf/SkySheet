import Foundation
import SkySheetCore
import SkySheetFiles
import SkyZip

/// 读文件排查第 2 条、保存排查第 3 条（2026-11-16）：没改过的公式保存时照原样带上 `<f>` 的类型和全部属性
/// （模拟运算表、共享公式、ca……），核对也要看得出丢了；主格切不了词的共享公式，跟随者不能写成引用错的公式。
@MainActor
func storedFormulaChecks() {
    func cell(_ workbook: Workbook, _ a1: String) -> Cell? { workbook.sheets[0].cells[CellAddress(a1: a1)!] }

    group("xlsx: a shared formula SkySheet can't shift isn't read as its master's formula") {
        let (workbook, _) = try openForEditing(try storedFormulaWorkbook())
        checkEqual(cell(workbook, "B2")?.formula?.source, "", "B2's own formula is unknown, not B1's text")
        checkEqual(cell(workbook, "B2")?.value, .number(5), "it shows the value Excel saved")
        checkEqual(cell(workbook, "E2")?.formula?.source, "SUM(Table1[Amount])*$A$1",
                   "no relative reference outside the brackets: the master's text is the follower's formula")
        checkEqual(cell(workbook, "D3")?.formula?.source, "A3*10", "shiftable shared formulas still expand")
    }

    group("xlsx write: unchanged formulas keep their type and attributes") {
        let (original, source) = try openForEditing(try storedFormulaWorkbook())
        var workbook = original
        workbook.enter(.number(1, format: nil), at: CellAddress(a1: "K5")!, sheet: 0)
        Recalculator.recalculate(&workbook, options: RecalcOptions(today: checkToday))
        let (result, reread) = try save(workbook, source: source, baseline: original)
        let xml = try sheetXML(result)
        check(xml.contains("<c r=\"B1\"><f t=\"shared\" ref=\"B1:B3\" si=\"0\">A1+SUM(Table1[Amount])</f>"),
              "the master of the shared formula SkySheet can't shift stays a master")
        check(xml.contains("<c r=\"B2\"><f t=\"shared\" si=\"0\"/>"), "its follower stays a follower (not B1's text)")
        check(xml.contains("<c r=\"D1\"><f t=\"shared\" ref=\"D1:D3\" si=\"1\">A1*10</f>")
              && xml.contains("<c r=\"D3\"><f t=\"shared\" si=\"1\"/>"), "an untouched shared formula is written as it was")
        check(xml.contains("<c r=\"H2\"><f t=\"dataTable\" ref=\"H2:H3\" dt2D=\"0\" dtr=\"0\" r1=\"J1\"/>"),
              "the data table definition is kept")
        check(xml.contains("<c r=\"C1\"><f ca=\"1\">A1*3</f>"), "other attributes are kept too")
        checkEqual(cell(reread.workbook, "D3")?.formula?.source, "A3*10", "followers read back the same")
    }

    group("xlsx write: changing the master of a shared formula SkySheet can't shift stops the save") {
        let (original, source) = try openForEditing(try storedFormulaWorkbook())
        var workbook = original
        workbook.enter(.number(7, format: nil), at: CellAddress(a1: "B1")!, sheet: 0)
        Recalculator.recalculate(&workbook, options: RecalcOptions(today: checkToday))
        do {
            let result = try XLSXWriter.write(workbook, source: source, baseline: original)
            let b2 = try sheetXML(result).components(separatedBy: "<c r=\"B2\"").dropFirst().first ?? ""
            fail("saved anyway; B2 became \(b2.prefix(60))")
        } catch let error as XLSXWriteError {
            check("\(error)".contains("\"B2\"") && "\(error)".contains("\"B1\""), "the error names B2 and B1: \(error)")
        }
    }

    group("xlsx write: changing a follower of a shared formula SkySheet can't shift keeps the rest shared") {
        let (original, source) = try openForEditing(try storedFormulaWorkbook())
        var workbook = original
        workbook.enter(.number(9, format: nil), at: CellAddress(a1: "B2")!, sheet: 0)
        Recalculator.recalculate(&workbook, options: RecalcOptions(today: checkToday))
        let (result, reread) = try save(workbook, source: source, baseline: original)
        let xml = try sheetXML(result)
        check(xml.contains("<c r=\"B1\"><f t=\"shared\" ref=\"B1:B3\" si=\"0\">A1+SUM(Table1[Amount])</f>"),
              "the master stays shared")
        check(xml.contains("<c r=\"B3\"><f t=\"shared\" si=\"0\"/>"), "the untouched follower stays a follower")
        check(xml.contains("<c r=\"B2\"><v>9</v></c>"), "the changed cell has its new content")
        checkEqual(cell(reread.workbook, "B2")?.value, .number(9), "read back")
        checkEqual(cell(reread.workbook, "B3")?.value, .number(6), "the follower keeps its value")
    }

    group("xlsx write: shared formulas SkySheet can shift are written cell by cell once one changes") {
        // 和以前一样：能平移的组改了一格，别的格子按自己的公式一格一格写；平移不改原文的（E 列）主格改了也照存。
        let (original, source) = try openForEditing(try storedFormulaWorkbook())
        var workbook = original
        workbook.enter(.number(0, format: nil), at: CellAddress(a1: "D2")!, sheet: 0)
        workbook.enter(.number(0, format: nil), at: CellAddress(a1: "E1")!, sheet: 0)
        Recalculator.recalculate(&workbook, options: RecalcOptions(today: checkToday))
        let (result, _) = try save(workbook, source: source, baseline: original)
        let xml = try sheetXML(result)
        check(xml.contains("<c r=\"D1\"><f>A1*10</f>") && xml.contains("<c r=\"D3\"><f>A3*10</f>"), "D1, D3 written out")
        check(!xml.contains("si=\"1\""), "group 1 is gone")
        check(xml.contains("<c r=\"E2\"><f>SUM(Table1[Amount])*$A$1</f>"), "E2 written with its own (unchanged) formula")
    }

    group("xlsx write: a copied sheet doesn't get B1's formula in B2") {
        let (original, source) = try openForEditing(try storedFormulaWorkbook())
        var workbook = original
        let copy = workbook.duplicateSheet(0)
        Recalculator.recalculate(&workbook, options: RecalcOptions(today: checkToday))
        let (result, reread) = try save(workbook, source: source, baseline: original)
        let name = try zipContents(result.data).keys.first { $0.hasPrefix("xl/worksheets/sheet") && $0 != "xl/worksheets/sheet1.xml" }
        let xml = String(decoding: try zipContents(result.data)[name ?? ""] ?? Data(), as: UTF8.self)
        let b2 = xml.components(separatedBy: "<c r=\"B2\"").dropFirst().first?.components(separatedBy: "</c>").first ?? ""
        check(!b2.isEmpty && !b2.contains("A1+SUM"), "the copy's B2 is not written as B1's formula: \(b2)")
        checkEqual(reread.workbook.sheets[copy].cells[CellAddress(a1: "B2")!]?.value, .number(5), "it keeps the value")
    }

    group("xlsx: a shared formula with only names in it is every follower's formula") {
        // 第一轮审查第 2 条：Sheet1!Rate（带 sheet 名的定义名称）切不了词，但平移不改它，main 给跟随者的原文本来就对。
        let (workbook, _) = try openForEditing(try namespacedPackage(sheetBody: """
            <sheetData><row r="1"><c r="B1"><f t="shared" ref="B1:B3" si="0">Sheet1!Rate*2</f><v>2</v></c></row>\
            <row r="2"><c r="B2"><f t="shared" si="0"/><v>2</v></c></row>\
            <row r="3"><c r="B3"><f t="shared" si="0"/><v>2</v></c></row></sheetData>
            """))
        checkEqual(cell(workbook, "B3")?.formula?.source, "Sheet1!Rate*2", "B3 has B1's formula")
    }

    group("xlsx write: a copied sheet keeps its shared formulas and data table as they were") {
        // 第一轮审查第 2 条：复制表（Duplicate Sheet、AI 的 copy_from）以前把算不出来的跟随者和模拟运算表写成 <f></f>。
        let (original, source) = try openForEditing(try storedFormulaWorkbook())
        var workbook = original
        let copy = workbook.duplicateSheet(0)
        Recalculator.recalculate(&workbook, options: RecalcOptions(today: checkToday))
        let (result, reread) = try save(workbook, source: source, baseline: original)
        let parts = try zipContents(result.data)
        let name = parts.keys.first { $0.hasPrefix("xl/worksheets/sheet") && $0 != "xl/worksheets/sheet1.xml" }
        let xml = String(decoding: parts[name ?? ""] ?? Data(), as: UTF8.self)
        check(xml.contains("<c r=\"B1\"><f t=\"shared\" ref=\"B1:B3\" si=\"0\">A1+SUM(Table1[Amount])</f>")
              && xml.contains("<c r=\"B2\"><f t=\"shared\" si=\"0\"/>") && xml.contains("<c r=\"B3\"><f t=\"shared\" si=\"0\"/>"),
              "the copy keeps the shared formula, master and followers where they were")
        check(xml.contains("<c r=\"H2\"><f t=\"dataTable\" ref=\"H2:H3\" dt2D=\"0\" dtr=\"0\" r1=\"J1\"/>"), "and the data table")
        check(!xml.contains("<f></f>") && !xml.contains("<f/>"), "no empty formulas in the copy")
        checkEqual(cell(reread.workbook, "B2")?.value, .number(5), "the original keeps its value")
        checkEqual(reread.workbook.sheets[copy].cells[CellAddress(a1: "B2")!]?.value, .number(5), "so does the copy")
    }

    group("xlsx write: a formula SkySheet doesn't know is never written as an empty <f>") {
        // 第一轮审查第 2 条：任何时候都不写 <f></f>（Excel 会要修复）。公式原文是空的、又没有原来的 <f> 可以照写的格子
        // （比如从算不出来的跟随者复制过来的），只写值。
        let (original, source) = try openForEditing(try storedFormulaWorkbook())
        var workbook = original
        workbook.sheets[0].cells[CellAddress(a1: "K1")!] = Cell(value: .number(5),
                                                               formula: CellFormula(source: "", cachedValue: .number(5)))
        Recalculator.recalculate(&workbook, options: RecalcOptions(today: checkToday))
        let (result, reread) = try save(workbook, source: source, baseline: original)
        let xml = try sheetXML(result)
        check(!xml.contains("<f></f>") && !xml.contains("<f/>"), "no empty <f>")
        checkEqual(cell(reread.workbook, "K1")?.value, .number(5), "the value is kept")
    }

    group("xlsx write: the save check notices a lost data table") {
        let (original, source) = try openForEditing(try storedFormulaWorkbook())
        var workbook = original
        workbook.enter(.number(1, format: nil), at: CellAddress(a1: "K5")!, sheet: 0)
        Recalculator.recalculate(&workbook, options: RecalcOptions(today: checkToday))
        let result = try XLSXWriter.write(workbook, source: source, baseline: original)
        var parts = try zipContents(result.data)
        let tampered = try sheetXML(result).replacingOccurrences(
            of: "<f t=\"dataTable\" ref=\"H2:H3\" dt2D=\"0\" dtr=\"0\" r1=\"J1\"/>", with: "<f></f>")
        parts["xl/worksheets/sheet1.xml"] = Data(tampered.utf8)
        var writer = ZipWriter()
        for entry in try ZipArchive(data: result.data).entries where !entry.isDirectory {
            try writer.addFile(entry.name, contents: parts[entry.name] ?? Data())
        }
        let tamperedData = writer.finished()
        do throws(XLSXWriteError) {
            _ = try SaveVerifier.verify(tamperedData, written: result, workbook: workbook, source: source)
            fail("a file without the data table passed the check")
        } catch {
            checkEqual(error, .verificationFailed("Sheet “Data”: cell H2 doesn't match after saving."), "names the cell")
        }
    }

    group("xlsx: sheets with data tables can't take new rows or columns") {
        let (_, source) = try openForEditing(try storedFormulaWorkbook())
        checkEqual(source.structureLock(forSheet: 1), .otherContent("data table"), "a data table points at its cells")
        let shared = try namespacedPackage(sheetBody: """
            <sheetData><row r="1"><c r="A1"><v>1</v></c><c r="B1"><f t="shared" ref="B1:B2" si="0">A1*2</f><v>2</v></c></row>\
            <row r="2"><c r="A2"><v>2</v></c><c r="B2"><f t="shared" si="0"/><v>4</v></c></row></sheetData>
            """)
        checkEqual(try XLSXReader.readDocument(shared).source.structureLock(forSheet: 1), nil, "shared formulas don't lock")
    }
}

/// 一张 Data：B1:B3 是主格切不了词的共享公式（结构化引用加相对引用），D1:D3 能平移，E1:E2 切不了词但平移不改它，
/// C1 带 ca，H2:H3 是单变量模拟运算表（输入格 J1，公式行 H1，代入值 G2:G3）。缓存值都是 Excel 会存的样子。
func storedFormulaWorkbook() throws -> Data {
    try namespacedPackage(sheetBody: """
        <sheetData><row r="1"><c r="A1"><v>1</v></c>\
        <c r="B1"><f t="shared" ref="B1:B3" si="0">A1+SUM(Table1[Amount])</f><v>4</v></c>\
        <c r="C1"><f ca="1">A1*3</f><v>3</v></c>\
        <c r="D1"><f t="shared" ref="D1:D3" si="1">A1*10</f><v>10</v></c>\
        <c r="E1"><f t="shared" ref="E1:E2" si="2">SUM(Table1[Amount])*$A$1</f><v>3</v></c>\
        <c r="H1"><f>J1*2</f><v>2</v></c><c r="J1"><v>1</v></c></row>\
        <row r="2"><c r="A2"><v>2</v></c><c r="B2"><f t="shared" si="0"/><v>5</v></c>\
        <c r="D2"><f t="shared" si="1"/><v>20</v></c><c r="E2"><f t="shared" si="2"/><v>3</v></c>\
        <c r="G2"><v>2</v></c><c r="H2"><f t="dataTable" ref="H2:H3" dt2D="0" dtr="0" r1="J1"/><v>4</v></c></row>\
        <row r="3"><c r="A3"><v>3</v></c><c r="B3"><f t="shared" si="0"/><v>6</v></c>\
        <c r="D3"><f t="shared" si="1"/><v>30</v></c><c r="G3"><v>3</v></c><c r="H3"><v>6</v></c></row></sheetData>
        """)
}

private func sheetXML(_ result: XLSXWriteResult) throws -> String {
    String(decoding: try zipContents(result.data)["xl/worksheets/sheet1.xml"] ?? Data(), as: UTF8.self)
}
