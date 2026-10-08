import Foundation
import SkySheetCore
@testable import SkySheetFiles
import SkyZip

/// 写 xlsx（设计 7.2 节）：没动过的部件原字节照抄；改过的 sheet 只重写我们管的元素；新样式、新文字只往后加；
/// 每次保存都过一遍 SaveVerifier（第三道保险）。用到内部的零件，所以 @testable（自检只在 debug 下编）。
@MainActor
func xlsxWriteChecks() {
    group("xlsx write: XML pieces") {
        let source = """
            <?xml version="1.0"?><!-- note --><x:root xmlns:x="urn:m" xmlns:r="urn:r" a="1">\
            <x:b k="v"/><x:c><x:d>t<![CDATA[<x:e/>]]></x:d><?pi x?></x:c><!-- skip --><x:f/></x:root>
            """
        guard var parts = XMLFragments(Data(source.utf8)) else { fail("could not split"); return }
        checkEqual(parts.children.map(\.name), ["b", "c", "f"], "direct children, comments and CDATA skipped")
        checkEqual(parts.prefix, "x:", "root prefix")
        checkEqual(parts.prefix(forNamespace: "urn:r"), "r:", "prefix for a namespace")
        checkEqual(String(decoding: parts.serialized(), as: UTF8.self), source.replacingOccurrences(of: "<!-- skip -->", with: ""),
                   "serialized back unchanged, except comments between the root's children")
        parts.set("e", raw: "<x:e/>", order: ["b", "c", "e", "f"])
        checkEqual(parts.children.map(\.name), ["b", "c", "e", "f"], "inserted in schema order")
        parts.set("c", raw: nil, order: [])
        checkEqual(parts.children.map(\.name), ["b", "e", "f"], "removed")
        checkEqual(XMLFragments(Data("<a/>".utf8))?.rootStart, "<a>", "self-closing root opens up")

        let element = "<x:sheetView tabSelected=\"1\" note='a&amp;b'><x:selection tabSelected=\"0\"/></x:sheetView>"
        checkEqual(XMLFragments.attribute("note", in: element), "a&b", "attribute value unescaped")
        checkEqual(XMLFragments.settingAttribute("tabSelected", to: nil, in: element),
                   "<x:sheetView note='a&amp;b'><x:selection tabSelected=\"0\"/></x:sheetView>", "only the first tag changes")
        checkEqual(XMLFragments.settingAttribute("zoom", to: "90", in: "<v/>"), "<v zoom=\"90\"/>", "attribute added")
        checkEqual(XMLFragments.appending(["<n/>"], to: "<list count=\"1\"><n/></list>", name: "list"),
                   "<list count=\"2\"><n/><n/></list>", "list grows and recounts")

        let tricky = "a_x0041_b\r\n\t<&>\u{1}"
        checkEqual(XMLText.decodeEscapes(XMLText.unescape(XMLText.text(tricky))), tricky, "_xHHHH_ round trip")
        checkEqual(XMLText.text("1\r\n2"), "1_x000D_\n2", "carriage return written the Excel way")
        checkEqual(XMLText.unescape(XMLText.attribute("\"<a&b>\"\n")), "\"<a&b>\"\n", "attribute round trip")

        var strings = SharedStringTable(existing: ["a", "b", "rich"], rich: [2])
        checkEqual(strings.index(of: "b"), 1, "existing text keeps its index")
        checkEqual(strings.index(of: "rich"), 3, "rich entries are not reused for other cells")
        checkEqual(strings.index(of: "rich", original: 2), 2, "but the cell that used it keeps it")
        checkEqual(strings.index(of: "new"), 4, "new text appended")
        checkEqual(strings.appended, ["rich", "new"], "appended in order")

        do {
            var changed = StyleTable()
            changed.fonts[0].bold = true
            _ = try StylesWriter.additions(from: StyleTable(), to: changed)
            fail("an edited existing font was accepted")
        } catch let error as XLSXWriteError {
            checkEqual(error, .existingStylesChanged, "existing styles are never rewritten")
        }
    }

    group("xlsx write: saving loan.xlsx without changes copies every part") {
        let original = try Data(contentsOf: fixtureURL("loan.xlsx"))
        let opened = try openForEditing(original)
        let (result, _) = try save(opened.workbook, source: opened.source, baseline: opened.workbook)
        check(result.regeneratedSheets.isEmpty, "no sheet regenerated")
        let before = try zipContents(original)
        let after = try zipContents(result.data)
        checkEqual(after.keys.sorted(), before.keys.sorted(), "same parts")
        check(before.allSatisfy { after[$0.key] == $0.value }, "every part byte-identical")
        checkEqual(result.copiedEntries.count, before.count, "all copied without re-compressing")
        checkEqual(try ZipArchive(data: result.data).entries.first?.name, "[Content_Types].xml", "content types first")
    }

    group("xlsx write: editing a cell of loan.xlsx") {
        let original = try Data(contentsOf: fixtureURL("loan.xlsx"))
        var opened = try openForEditing(original)
        let baseline = opened.workbook
        opened.workbook.enter(.number(Decimal(string: "0.031")!, format: nil), at: CellAddress(a1: "I3")!, sheet: 0)
        Recalculator.recalculate(&opened.workbook, options: RecalcOptions(today: checkToday))
        let (result, reread) = try save(opened.workbook, source: opened.source, baseline: baseline)
        checkEqual(result.regeneratedSheets, [1], "only the edited sheet is rewritten")

        let cells = reread.workbook.sheets[0].cells
        checkEqual(cells[CellAddress(a1: "I3")!]?.value, .number(Decimal(string: "0.031")!), "new value saved")
        checkEqual(cells[CellAddress(a1: "J3")!]?.formula?.source, "I3", "formulas saved without the leading =")
        checkEqual(cells[CellAddress(a1: "J3")!]?.value, .number(Decimal(string: "0.031")!), "with fresh cached values")
        checkEqual(cells[CellAddress(a1: "O1")!]?.styleIndex, 6, "empty styled cells kept")

        let before = try zipContents(original)
        let after = try zipContents(result.data)
        for part in ["xl/styles.xml", "xl/theme/theme1.xml", "xl/drawings/drawing1.xml", "xl/drawings/media/image1.png",
                     "xl/sharedStrings.xml", "xl/worksheets/_rels/sheet1.xml.rels", "docProps/core.xml"] {
            check(before[part] != nil && after[part] == before[part], "\(part) copied unchanged")
        }
        let sheetXML = String(decoding: after["xl/worksheets/sheet1.xml"] ?? Data(), as: UTF8.self)
        let order = ["<sheetPr>", "<dimension ", "<sheetViews>", "<cols>", "<sheetData>", "<drawing r:id=\"rId0\"/>"]
        let positions = order.compactMap { sheetXML.range(of: $0)?.lowerBound }
        check(positions.count == order.count && positions == positions.sorted(), "foreign elements kept, in schema order")
        check(sheetXML.contains("<dimension ref=\"A1:AG212\"/>"), "dimension written as a range")
        check(sheetXML.contains("<pane xSplit=\"1\" ySplit=\"1\" topLeftCell=\"B2\" state=\"frozen\"/>"), "untouched pane kept as is")
        let workbookXML = String(decoding: after["xl/workbook.xml"] ?? Data(), as: UTF8.self)
        check(workbookXML.contains("<calcPr fullCalcOnLoad=\"1\"/>"), "other apps recalculate on open")
        check(workbookXML.contains("<sheet name=\"Loan\" sheetId=\"1\" r:id=\"rId3\"/>"), "sheet list untouched")
    }

    group("xlsx write: new text and new number formats are appended") {
        let original = try Data(contentsOf: fixtureURL("loan.xlsx"))
        var opened = try openForEditing(original)
        let baseline = opened.workbook
        let styleCount = baseline.styles.cellFormats.count
        opened.workbook.enter(CellInput.parse("全新的备注 & <标记>"), at: CellAddress(a1: "P5")!, sheet: 0)
        opened.workbook.enter(CellInput.parse("¥1,234.50"), at: CellAddress(a1: "A215")!, sheet: 0)
        opened.workbook.enter(CellInput.parse("贷款类型"), at: CellAddress(a1: "B215")!, sheet: 0)
        let (result, reread) = try save(opened.workbook, source: opened.source, baseline: baseline)
        let cells = reread.workbook.sheets[0].cells
        checkEqual(cells[CellAddress(a1: "P5")!]?.value, .text("全新的备注 & <标记>"), "new text")
        checkEqual(reread.workbook.styles.formatCode(forStyle: cells[CellAddress(a1: "A215")!]?.styleIndex ?? 0),
                   "\"¥\"#,##0.00", "new number format")
        checkEqual(cells[CellAddress(a1: "A215")!]?.styleIndex, styleCount, "new style appended after the existing ones")
        checkEqual(reread.workbook.styles.customNumberFormats[310], "\"¥\"#,##0.00", "custom format id after Tencent's 300s")

        let after = try zipContents(result.data)
        let strings = String(decoding: after["xl/sharedStrings.xml"] ?? Data(), as: UTF8.self)
        check(strings.contains("uniqueCount=\"47\"") && !strings.contains(" count="), "one new string; count dropped")
        check(strings.hasSuffix("<si><t xml:space=\"preserve\">全新的备注 &amp; &lt;标记&gt;</t></si></sst>"), "appended last")
        let sheetXML = String(decoding: after["xl/worksheets/sheet1.xml"] ?? Data(), as: UTF8.self)
        check(sheetXML.contains("<c r=\"B215\" t=\"s\"><v>0</v></c>"), "existing text reuses its index")
        let styles = String(decoding: after["xl/styles.xml"] ?? Data(), as: UTF8.self)
        check(styles.contains("<cellXfs count=\"\(styleCount + 1)\">"), "cellXfs recounted")
        check(styles.contains("<numFmts count=\"11\">"), "numFmts recounted")
    }

    group("xlsx write: duplicating, renaming and deleting sheets") {
        let original = try Data(contentsOf: fixtureURL("loan.xlsx"))
        var opened = try openForEditing(original)
        var baseline = opened.workbook
        var source = opened.source
        let copy = opened.workbook.duplicateSheet(0)
        try opened.workbook.renameSheet(copy, to: "方案 A")
        opened.workbook.sheets[copy].cells[CellAddress(a1: "B2")!] = Cell(value: .number(60000), styleIndex: 8)
        Recalculator.recalculate(&opened.workbook, options: RecalcOptions(today: checkToday))
        var (result, reread) = try save(opened.workbook, source: source, baseline: baseline)
        checkEqual(result.regeneratedSheets, [2], "only the new sheet is generated; the original is copied")
        checkEqual(reread.workbook.sheets.map(\.name), ["Loan", "方案 A"], "both sheets saved")
        checkEqual(reread.workbook.sheets[1].cells[CellAddress(a1: "F2")!]?.value, .number(Decimal(string: "922.57")!),
                   "the copy's formulas saved with values")
        var after = try zipContents(result.data)
        let workbookXML = String(decoding: after["xl/workbook.xml"] ?? Data(), as: UTF8.self)
        check(workbookXML.contains("<sheet name=\"方案 A\" sheetId=\"2\" r:id=\"rIdSky1\"/>"), "new sheet listed")
        let types = String(decoding: after["[Content_Types].xml"] ?? Data(), as: UTF8.self)
        check(types.contains("<Override PartName=\"/xl/worksheets/sheet2.xml\""), "content type for the new part")
        let copyXML = String(decoding: after["xl/worksheets/sheet2.xml"] ?? Data(), as: UTF8.self)
        check(!copyXML.contains("tabSelected") && !copyXML.contains("<drawing"), "the copy has no selection or drawing")

        // 存完以后：读回来的成了新的原包，内存里的成了新的基准。再改名、删掉原来那张。
        source = reread.source
        baseline = opened.workbook
        try opened.workbook.deleteSheet(0)
        try opened.workbook.renameSheet(0, to: "Loan")
        (result, reread) = try save(opened.workbook, source: source, baseline: baseline)
        checkEqual(reread.workbook.sheets.map(\.name), ["Loan"], "one sheet left")
        after = try zipContents(result.data)
        check(after["xl/worksheets/sheet1.xml"] == nil && after["xl/worksheets/_rels/sheet1.xml.rels"] == nil,
              "the deleted sheet's part and relationships are gone")
        check(after["xl/worksheets/sheet2.xml"] != nil, "the remaining sheet is copied")
        let types2 = String(decoding: after["[Content_Types].xml"] ?? Data(), as: UTF8.self)
        check(!types2.contains("/xl/worksheets/sheet1.xml"), "its content type is gone too")
        let rels = String(decoding: after["xl/_rels/workbook.xml.rels"] ?? Data(), as: UTF8.self)
        check(!rels.contains("Id=\"rId3\""), "its relationship is gone")
    }

    group("xlsx write: csv saved as xlsx") {
        let csv = Data("日期,金额,备注\n2025-12-01,1234.5,首期\n2025-12-02,-8,\"a,b\"\n,5%,\n".utf8)
        let document = try CSVReader.read(csv, sheetName: "明细")
        var workbook = document.workbook
        workbook.enter(.formula("SUM(B2:B3)"), at: CellAddress(a1: "B5")!, sheet: 0)
        Recalculator.recalculate(&workbook, options: RecalcOptions(today: checkToday))
        let (result, reread) = try save(workbook, source: nil, baseline: nil)
        checkEqual(reread.workbook.sheets.map(\.name), ["明细"], "sheet name")
        checkEqual(reread.workbook.styles, workbook.styles, "styles round trip exactly")
        checkEqual(reread.workbook.sheets[0].cells[CellAddress(a1: "B5")!]?.value, .number(Decimal(string: "1226.5")!),
                   "formula value saved")
        let parts = try zipContents(result.data).keys.sorted()
        checkEqual(parts, ["[Content_Types].xml", "_rels/.rels", "docProps/app.xml", "docProps/core.xml",
                           "xl/_rels/workbook.xml.rels", "xl/sharedStrings.xml", "xl/styles.xml", "xl/workbook.xml",
                           "xl/worksheets/sheet1.xml"], "a complete package")
    }

    group("xlsx write: unusual files keep what we don't understand") {
        let data = try unusualWorkbook()
        var opened = try openForEditing(data)
        let baseline = opened.workbook
        opened.workbook.enter(.value(.text("改过")), at: CellAddress(a1: "D1")!, sheet: 0)
        _ = opened.workbook.duplicateSheet(0)
        Recalculator.recalculate(&opened.workbook, options: RecalcOptions(today: checkToday))
        let (result, reread) = try save(opened.workbook, source: opened.source, baseline: baseline)
        checkEqual(reread.workbook.sheets.map(\.name), ["Data", "Data (2)"], "sheets")
        checkEqual(reread.workbook.nextSheetID, 11, "ids stay clear of the chart sheet's")
        let after = try zipContents(result.data)
        let workbookXML = String(decoding: after["xl/workbook.xml"] ?? Data(), as: UTF8.self)
        check(workbookXML.contains("<x:sheet name=\"Chart\" sheetId=\"9\" r:id=\"rId9\"/><x:sheet name=\"Data\""),
              "the chart sheet stays in front")
        check(workbookXML.contains("<x:sheet name=\"Data (2)\" sheetId=\"10\" r:id=\"rIdSky1\"/>"), "new entry uses the x: prefix")
        let sheetXML = String(decoding: after["xl/worksheets/data.xml"] ?? Data(), as: UTF8.self)
        check(sheetXML.contains("<x:c r=\"D1\" t=\"s\">") && sheetXML.contains("<x:f t=\"array\" ref=\"E1:E2\">"),
              "generated cells use the root's prefix")
        checkEqual(reread.workbook.sheets[0].cells[CellAddress(a1: "B3")!]?.formula?.source, "A3*2",
                   "shared formulas written out one by one")
    }

    group("xlsx write: the save check catches a bad file") {
        let original = try Data(contentsOf: fixtureURL("loan.xlsx"))
        var opened = try openForEditing(original)
        let baseline = opened.workbook
        opened.workbook.enter(.number(1, format: nil), at: CellAddress(a1: "B2")!, sheet: 0)
        let result = try XLSXWriter.write(opened.workbook, source: opened.source, baseline: baseline)
        var different = opened.workbook
        different.enter(.number(2, format: nil), at: CellAddress(a1: "B2")!, sheet: 0)
        do {
            _ = try SaveVerifier.verify(result.data, written: result, workbook: different, source: opened.source)
            fail("a mismatching file passed the check")
        } catch let error as XLSXWriteError {
            checkEqual(error, .verificationFailed("Sheet “Loan”: cell B2 doesn't match after saving."), "names the cell")
        }
        do {
            _ = try SaveVerifier.verify(Data("not a zip".utf8), written: result, workbook: opened.workbook, source: opened.source)
            fail("garbage passed the check")
        } catch let error as XLSXWriteError {
            guard case .verificationFailed(let message) = error else { throw error }
            check(message.contains("can't be read back"), "unreadable output rejected")
        }
    }
}

/// 第四、五道保险的存储：备份轮换、恢复副本。都在临时目录里试。
@MainActor
func safetyStoreChecks() {
    group("safety: backups keep the newest ten per file") {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = BackupStore(root: folder.appendingPathComponent("Backups"), keep: 3)
        let file = folder.appendingPathComponent("loan.xlsx")
        let otherFolder = folder.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)
        let sameName = otherFolder.appendingPathComponent("loan.xlsx")
        try Data("other".utf8).write(to: sameName)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        for minute in 0..<5 {
            try Data("version \(minute)".utf8).write(to: file)
            try store.backUp(file, now: start.addingTimeInterval(Double(minute) * 60))
        }
        try store.backUp(sameName, now: start)
        let kept = store.backups(of: file)
        checkEqual(kept.count, 3, "only the newest copies are kept")
        checkEqual(try String(contentsOf: kept[0], encoding: .utf8), "version 4", "newest first")
        checkEqual(kept.map(\.pathExtension), ["xlsx", "xlsx", "xlsx"], "same extension as the original")
        checkEqual(store.backups(of: sameName).count, 1, "a file with the same name elsewhere has its own history")
        try store.backUp(file, now: start.addingTimeInterval(240))
        check(store.backups(of: file)[0].lastPathComponent.hasSuffix("_2.xlsx"), "two backups in the same second both kept")
    }

    group("safety: recovery copies") {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = RecoveryStore(root: folder)
        let first = RecoveryStore.Entry(id: UUID(), originalPath: "/tmp/loan.xlsx", displayName: "loan.xlsx",
                                        savedAt: Date(timeIntervalSince1970: 1_790_000_000))
        let second = RecoveryStore.Entry(id: UUID(), originalPath: nil, displayName: "Untitled",
                                         savedAt: Date(timeIntervalSince1970: 1_790_000_060))
        try store.save(Data("one".utf8), entry: first)
        try store.save(Data("two".utf8), entry: second)
        checkEqual(store.entries(), [second, first], "listed newest first")
        checkEqual(try Data(contentsOf: store.dataURL(first.id)), Data("one".utf8), "data kept")
        store.remove(second.id)
        checkEqual(store.entries(), [first], "removed when the document closes normally")
        try FileManager.default.removeItem(at: store.dataURL(first.id))
        checkEqual(store.entries(), [], "an entry without its data is ignored")
    }
}

/// 打开时的样子：读进来、整本重算一遍（App 打开文件时也是这样）。
private func openForEditing(_ data: Data) throws -> (workbook: Workbook, source: XLSXSource) {
    var document = try XLSXReader.readDocument(data)
    Recalculator.recalculate(&document.workbook, options: RecalcOptions(today: checkToday))
    return (document.workbook, document.source)
}

/// 和 App 一样存一遍：写，再读回来核对。设了环境变量 SKYSHEET_CHECK_OUTPUT（一个文件夹）就把存出来的文件留在那里，
/// 拿 Excel、Numbers、腾讯文档打开看（M3 的验收）。
@MainActor
private func save(_ workbook: Workbook, source: XLSXSource?, baseline: Workbook?) throws -> (XLSXWriteResult, XLSXDocument) {
    let result = try XLSXWriter.write(workbook, source: source, baseline: baseline,
                                      now: Date(timeIntervalSince1970: 1_790_000_000))
    if let folder = ProcessInfo.processInfo.environment["SKYSHEET_CHECK_OUTPUT"] {
        savedFiles += 1
        let name = "\(savedFiles)-" + Checks.currentGroup.replacingOccurrences(of: "xlsx write: ", with: "")
            .replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "/", with: "-") + ".xlsx"
        try result.data.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
    }
    return (result, try SaveVerifier.verify(result.data, written: result, workbook: workbook, source: source))
}

@MainActor private var savedFiles = 0

private func zipContents(_ data: Data) throws -> [String: Data] {
    let archive = try ZipArchive(data: data)
    var contents: [String: Data] = [:]
    for entry in archive.entries where !entry.isDirectory {
        contents[entry.name] = try archive.contents(of: entry)
    }
    return contents
}
