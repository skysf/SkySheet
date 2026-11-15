import Foundation
@testable import SkySheetCore
@testable import SkySheetDisplay
@testable import SkySheetFiles
import SkyZip

/// 按字符串做键的缓存（2026-11-15）：Swift 的 String 相等按「规范等价」算，é（U+00E9）和 e + U+0301 是同一个键；
/// 可公式切词按 Unicode 标量来，两种写法结果不同（e + U+0301 里的 U+0301 不是字母，`Cafe\u{301}!A1` 读不出来，
/// `Café!A1` 是一个引用）。字体量字也按标量：Verdana、Georgia 这类字体里两种写法宽度不同（本机实测）。
/// 缓存按 String 做键，先进去的那个就替后来的那个答了（Codex 审 PR #10 时指出解析缓存这一处）。
@MainActor
func exactTextChecks() {
    group("string keys: format literals preserve their own scalars") {
        // 格式原文来自文件或用户；缓存不能把分解写法里的 literal 换成先前的预组合写法。
        _ = ValueFormatter.format(.number(1), code: "\"\u{E9}\"0")
        let shown = ValueFormatter.format(.number(1), code: "\"e\u{301}\"0").text
        checkEqual(shown.unicodeScalars.map(\.value), [0x0065, 0x0301, 0x0031],
                   "the decomposed format keeps 0065 0301 0031")
    }

    group("string keys: shared strings preserve new and existing spellings") {
        let precomposed = "\u{E9}"
        let decomposed = "e\u{301}"
        var fresh = SharedStringTable()
        checkEqual(fresh.index(of: precomposed), 0, "first spelling")
        checkEqual(fresh.index(of: decomposed), 1, "new spelling gets its own item")
        var existing = SharedStringTable(existing: [precomposed, decomposed])
        checkEqual(existing.index(of: decomposed), 1, "existing decomposed item keeps its index")
        var rich = SharedStringTable(existing: [precomposed], rich: [0])
        checkEqual(rich.index(of: decomposed, original: 0), 1, "changed scalars don't reuse the original rich item")

        let workbook = Workbook(sheets: [makeSheet("Sheet1", id: 1, ["A1": precomposed, "A2": decomposed])])
        let written = try XLSXWriter.write(workbook, source: nil, baseline: nil)
        let saved = try XLSXReader.readDocument(written.data)
        guard case .text(let text)? = saved.workbook.sheets[0].cells[1, 0]?.value else {
            fail("missing shared string after saving"); return
        }
        checkEqual(text.unicodeScalars.map(\.value), [0x0065, 0x0301], "saved cell preserves its scalars")
    }

    group("string keys: package fallback only folds case") {
        let package = try OPCPackage(data: exactNameArchive())
        checkEqual(try package.data("A\u{30A}.XML"), Data([2]), "case fallback preserves decomposed spelling")
    }

    group("string keys: removing a relationship preserves its look-alike") {
        let xml = Data("<Relationships><Relationship Id=\"\u{E9}\"/><Relationship Id=\"e\u{301}\"/></Relationships>".utf8)
        let patched = try PackageIndex.patchRelationships(xml, part: "_rels/test.rels", removingIDs: [ExactText("\u{E9}")],
                                                          removingTypes: [], adding: [])
        let document = patched.flatMap(XMLFragments.init)
        checkEqual(document?.children.count, 1, "only the requested relationship is removed")
        let remainingID = document?.children.first.flatMap { XMLFragments.attribute("Id", in: $0.raw) }
        checkEqual(remainingID?.unicodeScalars.map(\.value), [0x0065, 0x0301], "the other relationship keeps its exact ID")
    }

    group("string keys: replacing a part preserves its look-alike") {
        let document = try XLSXReader.readDocument(exactPartWorkbook())
        var workbook = document.workbook
        workbook.sheets[0].cells[0, 0] = Cell(value: .number(11))
        let written = try XLSXWriter.write(workbook, source: document.source, baseline: document.workbook)
        let saved = try XLSXReader.readDocument(written.data)
        checkEqual(saved.workbook.sheets[0].cells[0, 0]?.value, .number(11), "requested part is replaced")
        checkEqual(saved.workbook.sheets[1].cells[0, 0]?.value, .number(2), "other spelling is copied unchanged")
    }

    group("string keys: removing a part preserves its look-alike") {
        let document = try XLSXReader.readDocument(exactPartWorkbook())
        var workbook = document.workbook
        workbook.sheets.removeFirst()
        let written = try XLSXWriter.write(workbook, source: document.source, baseline: document.workbook)
        let saved = try XLSXReader.readDocument(written.data)
        checkEqual(saved.workbook.sheets.first?.cells[0, 0]?.value, .number(2), "other spelling remains readable")
    }

    group("string keys: content type removal preserves its look-alike") {
        let xml = Data("<Types><Override PartName=\"/xl/%C3%A9.xml\"/><Override PartName=\"/xl/e%CC%81.xml\"/></Types>".utf8)
        let patched = try PackageIndex.patchContentTypes(xml, removing: [ExactText("xl/\u{E9}.xml")], adding: [])
        let document = patched.flatMap(XMLFragments.init)
        checkEqual(document?.children.count, 1, "only the requested override is removed")
    }

    group("string keys: structure lock scans the other sheet spelling") {
        let xml = "<conditionalFormatting><formula>One!A1</formula></conditionalFormatting>"
        let document = try XLSXReader.readDocument(exactPartWorkbook(secondSuffix: xml))
        checkEqual(document.source.structureLock(forSheet: 1), .referencedElsewhere("xl/worksheets/e\u{301}.xml"),
                   "the other sheet is not skipped as the target sheet")
    }

    group("string keys: structure lock distinguishes opaque parts from sheets") {
        let opaque = ("xl/worksheets/e\u{301}.xml", "<root><sheetData>One!A1</sheetData></root>")
        let document = try XLSXReader.readDocument(exactPartWorkbook(
            paths: ["xl/worksheets/one.xml", "xl/worksheets/\u{E9}.xml"], extra: [opaque]))
        checkEqual(document.source.structureLock(forSheet: 1), .referencedElsewhere(opaque.0),
                   "an opaque part's sheetData is not discarded as if it were a known sheet")
    }

    group("string keys: SQL column names preserve distinct spellings") {
        let sheet = makeSheet("Data", id: 1, ["A1": "\u{E9}", "B1": "e\u{301}", "A2": "1", "B2": "2"])
        let tables = QueryTables.tables(for: Workbook(sheets: [sheet]))
        let result = try SQLQuery.run("SELECT Data.\"e\u{301}\" FROM Data", tables: tables)
        checkEqual(result.rows, [[.real(2)]], "the decomposed header still names its own column")
    }

    group("string keys: canonically equivalent sources are different formulas") {
        // 两种写法 Swift 认为相等：这正是坑在哪。
        check("Caf\u{E9}!A1" == "Cafe\u{301}!A1", "Swift's String equality is canonical")

        // 先读到读不出来的那个，后一个有效的公式不能跟着「读不出来」（反过来也一样）。
        let cafe = makeSheet("Caf\u{E9}", id: 2, ["A1": "5"])
        var first = Workbook(sheets: [makeSheet("Sheet1", id: 1, ["B1": "=Cafe\u{301}!A1"]), cafe])
        Recalculator.recalculate(&first, options: RecalcOptions(today: checkToday))
        checkEqual(first.sheets[0].cells[CellAddress(a1: "B1")!]?.value, .error(.name), "the decomposed one can't be read")
        var second = Workbook(sheets: [makeSheet("Sheet1", id: 1, ["C1": "=Caf\u{E9}!A1"]), cafe])
        Recalculator.recalculate(&second, options: RecalcOptions(today: checkToday))
        checkEqual(second.sheets[0].cells[CellAddress(a1: "C1")!]?.value, num("5"),
                   "a valid formula in another workbook doesn't pick up its look-alike's failure")

        let gruen = makeSheet("Gr\u{FC}n", id: 2, ["A1": "6"])
        var valid = Workbook(sheets: [makeSheet("Sheet1", id: 1, ["B1": "=Gr\u{FC}n!A1"]), gruen])
        Recalculator.recalculate(&valid, options: RecalcOptions(today: checkToday))
        checkEqual(valid.sheets[0].cells[CellAddress(a1: "B1")!]?.value, num("6"), "the precomposed one is a reference")
        var lookAlike = Workbook(sheets: [makeSheet("Sheet1", id: 1, ["C1": "=Gru\u{308}n!A1"]), gruen])
        Recalculator.recalculate(&lookAlike, options: RecalcOptions(today: checkToday))
        checkEqual(lookAlike.sheets[0].cells[CellAddress(a1: "C1")!]?.value, .error(.name),
                   "an unreadable formula doesn't pick up its look-alike's success")

        // 重算计划「公式没变」的判断也按标量比。
        check(FormulaLayout.Entry(source: "Caf\u{E9}!A1", arrayRange: nil)
              != FormulaLayout.Entry(source: "Cafe\u{301}!A1", arrayRange: nil), "layout entries compare by scalars")

        // 同一格的公式只换了写法（重新载入文件时会这样）：格子的 == 看不出来，接着用的计划也得重排。
        let cache = RecalcCache()
        let address = CellAddress(a1: "B1")!
        var reloaded = Workbook(sheets: [makeSheet("Sheet1", id: 1, ["B1": "=Cafe\u{301}!A2"]),
                                         makeSheet("Caf\u{E9}", id: 2, ["A2": "7"])])
        Recalculator.recalculate(&reloaded, options: RecalcOptions(today: checkToday, cache: cache))
        checkEqual(reloaded.sheets[0].cells[address]?.value, .error(.name), "before: the decomposed form can't be read")
        var cell = reloaded.sheets[0].cells[address]!
        cell.formula!.source = "Caf\u{E9}!A2"
        check(cell == reloaded.sheets[0].cells[address]!, "Swift's == can't tell the two cells apart")
        reloaded.sheets[0].cells[address] = cell
        Recalculator.recalculate(&reloaded, options: RecalcOptions(today: checkToday, cache: cache))
        checkEqual(reloaded.sheets[0].cells[address]?.value, num("7"), "after: the reused plan follows the new spelling")
    }

    group("string keys: cached display text follows the cell's own scalars") {
        // 同一格从一种写法换成另一种（比如重新载入了文件）：显示的文字要跟着换，不能接着用记下的那一种
        // （有的字体里两种写法画出来不一样）。
        let cache = DisplayContentCache()
        let address = CellAddress(row: 0, column: 0)
        let style = StyleResolver(workbook: Workbook(sheets: [Sheet(id: 1, name: "Sheet1")])).style(0)
        let precomposed = Cell(value: .text("Vi\u{1EC7}t"))
        let decomposed = Cell(value: .text("Vie\u{323}\u{302}t"))
        _ = cache.content(of: precomposed, at: address, style: style, dateSystem: .from1900)
        let shown = cache.content(of: decomposed, at: address, style: style, dateSystem: .from1900).text
        check(Array(shown.unicodeScalars) == Array("Vie\u{323}\u{302}t".unicodeScalars),
              "shows the decomposed text, got \(shown.unicodeScalars.map { String($0.value, radix: 16) })")
    }
}

/// 两个名称字节不同的 ZIP 条目；先用不撞名的占位名拼包，再等长替换，免得读索引的自检依赖写索引已经修好。
func exactNameArchive() throws -> Data {
    var writer = ZipWriter()
    try writer.addFile("\u{212B}.xml", contents: Data([1]))
    try writer.addFile("B\u{30A}.xml", contents: Data([2]))
    var data = writer.finished()
    let placeholder = Data("B\u{30A}.xml".utf8)
    while let range = data.range(of: placeholder) {
        data.replaceSubrange(range, with: Data("A\u{30A}.xml".utf8))
    }
    return data
}

/// 只用合成数据，把两张 sheet 的部件名换成规范等价的两种写法；URI 用百分号编码，ZIP 名称用解码后的 UTF-8。
private func exactPartWorkbook(paths: [String] = ["xl/worksheets/\u{E9}.xml", "xl/worksheets/e\u{301}.xml"],
                               secondSuffix: String = "", extra: [(String, String)] = []) throws -> Data {
    let workbook = Workbook(sheets: [makeSheet("One", id: 1, ["A1": "1"]), makeSheet("Two", id: 2, ["A1": "2"])])
    let fresh = try XLSXWriter.write(workbook, source: nil, baseline: nil)
    let zip = try ZipArchive(data: fresh.data)
    var writer = ZipWriter()
    for entry in zip.entries {
        var name = entry.name
        var data = try zip.contents(of: entry)
        if name == "xl/worksheets/sheet1.xml" { name = paths[0] }
        if name == "xl/worksheets/sheet2.xml" {
            name = paths[1]
            data = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "</worksheet>",
                         with: secondSuffix + "</worksheet>").utf8)
        }
        if entry.name == "xl/_rels/workbook.xml.rels" || entry.name == "[Content_Types].xml" {
            var xml = String(decoding: data, as: UTF8.self)
            for index in paths.indices {
                let uri = paths[index].dropFirst(3).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
                xml = xml.replacingOccurrences(of: "worksheets/sheet\(index + 1).xml", with: uri)
            }
            data = Data(xml.utf8)
        }
        try writer.addFile(name, contents: data)
    }
    for (name, xml) in extra { try writer.addFile(name, contents: Data(xml.utf8)) }
    return writer.finished()
}
