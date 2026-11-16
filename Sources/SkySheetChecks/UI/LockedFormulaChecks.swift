import AppKit
import SkySheetCore
import SkySheetFiles
import SkyZip

/// 第一轮审查第 3、4、5 条：SkySheet 写不回去的公式占着的格子，改之前就拒绝——跟随者的公式算不出来的共享公式组的主格
/// （以前改了以后到保存才拒绝，从那以后存不了、恢复副本也写不出来），模拟运算表的整个区域（Excel 也不让只改一部分）。
/// 界面上是 SheetSession.apply 什么都不改；AI 那边是 AIContext.change 抛英文错误、撤销栈不动。
@MainActor
func lockedFormulaChecks() {
    func cell(_ session: SheetSession, _ a1: String) -> Cell? { session.workbook.sheets[0].cells[CellAddress(a1: a1)!] }
    func type(_ session: SheetSession, _ value: Int, at a1: String) {
        session.apply("Typing") { $0.enter(.number(Decimal(value), format: nil), at: CellAddress(a1: a1)!, sheet: 0) }
    }

    group("ui-32: the master of a shared formula SkySheet can't work out can't be changed") {
        let session = SheetSession(workbook: try XLSXReader.read(try sharedFormulaLockWorkbook()))
        var refusal: LockedFormulaChange?
        session.refusedChange = { refusal = $0 }
        let before = session.workbook
        type(session, 7, at: "B1")
        check(session.workbook == before, "typing over B1 is refused")
        checkEqual(refusal, LockedFormulaChange(sheet: "Data", cell: CellAddress(a1: "B1")!,
                                                reason: .sharedFormula(follower: CellAddress(a1: "B2")!)),
                   "the window is told which cell and why")
        session.apply("Clear") { $0.clearContents(CellRange(a1: "B1:B3")!, sheet: 0) }
        check(session.workbook == before, "clearing B1:B3 is refused (B1 is in it)")
        type(session, 9, at: "B2")
        checkEqual(cell(session, "B2")?.value, .number(9), "a follower can still be changed on its own")
        // 审查的例子：主格改不了，首行前插 3 行也就挪不动这一组（以前改成数值以后插行放行，空着的跟随者挪走，存成空公式）。
        do {
            try session.apply("Insert Rows") { _ = try $0.insert(3, .rows, at: 0, sheet: 0) }
            fail("rows were inserted above the group")
        } catch let error as StructureEditError {
            checkEqual(error, .unreadableFormula(sheet: "Data", cell: CellAddress(a1: "B1")!), "refused at B1")
        }
        checkEqual(cell(session, "B1")?.formula?.source, "A1+Inputs!Rate", "B1 is untouched")
    }

    group("ui-33: a data table can't be changed in part") {
        let session = SheetSession(workbook: try XLSXReader.read(try dataTableLockWorkbook()))
        var refusal: LockedFormulaChange?
        session.refusedChange = { refusal = $0 }
        let before = session.workbook
        type(session, 99, at: "H3")
        check(session.workbook == before, "a result cell is refused (Excel: Cannot change part of a data table)")
        checkEqual(refusal, LockedFormulaChange(sheet: "Data", cell: CellAddress(a1: "H3")!,
                                                reason: .dataTable(CellRange(a1: "H2:H3")!)), "with the table's range")
        type(session, 5, at: "H2")
        check(session.workbook == before, "so is the table's first cell")
        type(session, 5, at: "G2")
        checkEqual(cell(session, "G2")?.value, .number(5), "the input values next to it can change")
        do {
            try session.apply("Insert Rows") { _ = try $0.insert(1, .rows, at: 9, sheet: 0) }
            fail("rows were inserted on a sheet with a data table")
        } catch let error as StructureEditError {
            checkEqual(error, .unreadableFormula(sheet: "Data", cell: CellAddress(a1: "H2")!), "refused at the table")
        }
    }
}

/// 第二轮审查：文件里 `<f>` 的记录（共享公式的 si 这些）只配原来那一格的内容。内容一改（编辑、清空、粘贴、填充、AI 写入）
/// 记录就作废，撤销、重做时和内容一起回来；任何被接受的一串操作，结果都存得了。全走真的界面入口（apply、复制粘贴）。
@MainActor
func formulaRecordChecks() {
    func cell(_ session: SheetSession, _ a1: String) -> Cell? { session.workbook.sheets[0].cells[CellAddress(a1: a1)!] }
    func type(_ session: SheetSession, _ value: Int, at a1: String) {
        session.apply("Typing") { $0.enter(.number(Decimal(value), format: nil), at: CellAddress(a1: a1)!, sheet: 0) }
    }

    group("ui-34: a formula pasted over a follower doesn't take on the old shared formula") {
        // 清空 B1:B2 这组（算不出来）的 B2，再把另一组的跟随者 D2 粘到 B2：以前空原文对上了 B2 的旧记录，存出来 B2 又跟着 B1，
        // Excel 按错的主格重算，核对也看不出来。
        let document = try XLSXReader.readDocument(try twoUnknownGroupsWorkbook())
        let session = SheetSession(workbook: document.workbook)
        session.apply("Clear") { $0.clearContents(CellRange(a1: "B2")!, sheet: 0) }
        try paste(from: "D2", to: "B2", in: session)
        let xml = try savedSheet(session, document)
        check(!element(xml, "B2").contains("si=\"0\""), "B2 isn't written as a follower of B1: \(element(xml, "B2"))")
        check(element(xml, "D2").contains("<f t=\"shared\" si=\"1\"/>"), "the other group is kept as it was")
    }

    group("ui-35: every accepted edit leaves a workbook that saves") {
        // 清空 B2 以后这一组没有跟随者了，B1 能改；再粘上 D2：以前编辑都接受了，保存和恢复副本却一直失败。
        let document = try XLSXReader.readDocument(try twoUnknownGroupsWorkbook())
        let session = SheetSession(workbook: document.workbook)
        session.apply("Clear") { $0.clearContents(CellRange(a1: "B2")!, sheet: 0) }
        _ = try savedSheet(session, document)
        type(session, 9, at: "B1")
        checkEqual(cell(session, "B1")?.value, .number(9), "B1 can change once its follower is gone")
        _ = try savedSheet(session, document)
        try paste(from: "D2", to: "B2", in: session)
        _ = try savedSheet(session, document)
    }

    group("ui-36: undo and redo bring a follower's shared formula back and forth with it") {
        let document = try XLSXReader.readDocument(try twoUnknownGroupsWorkbook())
        let session = SheetSession(workbook: document.workbook)
        let manager = UndoManager()
        session.undoManager = manager
        AIUndoGrouping.step(manager) { session.apply("Clear") { $0.clearContents(CellRange(a1: "B2")!, sheet: 0) } }
        manager.undo()
        check(element(try savedSheet(session, document), "B2").contains("<f t=\"shared\" si=\"0\"/>"), "undo: B2 follows B1 again")
        type(session, 9, at: "B1")
        checkEqual(cell(session, "B1")?.formula?.source, "A1+Inputs!Rate", "so B1 can't change again")
        manager.redo()
        check(!element(try savedSheet(session, document), "B2").contains("<f"), "redo: B2 is empty again")
    }

    group("ui-37: a follower with only names and absolute references copies with its formula") {
        // 第二轮审查第 1 条：主式 Sheet1!Rate*$a$1 平移只是把 $a$1 写成大写，引用没动；以前判成算不准、跟随者原文清空，
        // 复制到别处一存只剩 #NAME?，公式就丢了。
        let document = try XLSXReader.readDocument(try namesOnlyWorkbook())
        let session = SheetSession(workbook: document.workbook)
        checkEqual(cell(session, "B2")?.formula?.source, "Sheet1!Rate*$a$1", "B2 has B1's formula")
        try paste(from: "B2", to: "K1", in: session)
        check(element(try savedSheet(session, document), "K1").contains("<f>Sheet1!Rate*$a$1</f>"), "the copy keeps it")
    }
}

/// 用界面的复制、粘贴（CellClip）把一格搬到另一格。
@MainActor
private func paste(from: String, to: String, in session: SheetSession) throws {
    session.select(CellAddress(a1: from)!)
    let clip = try session.clipOfSelection()
    session.select(CellAddress(a1: to)!)
    try session.paste(clip)
}

/// 和保存一样写一遍、过第三道保险，返回 sheet1.xml。写不了、核对不过就抛错。
@MainActor
private func savedSheet(_ session: SheetSession, _ document: XLSXDocument) throws -> String {
    let result = try XLSXWriter.write(session.workbook, source: document.source, baseline: document.workbook)
    _ = try SaveVerifier.verify(result.data, written: result, workbook: session.workbook, source: document.source)
    let archive = try ZipArchive(data: result.data)
    guard let entry = archive.entry(named: "xl/worksheets/sheet1.xml") else { return "" }
    return String(decoding: try archive.contents(of: entry), as: UTF8.self)
}

/// sheet XML 里一格的 `<c>`（到下一格或这一行结束为止），没有这一格是空串。
private func element(_ xml: String, _ a1: String) -> String {
    guard let start = xml.range(of: "<c r=\"\(a1)\"") else { return "" }
    let rest = xml[start.upperBound...]
    let end = [rest.range(of: "<c "), rest.range(of: "</row>")].compactMap { $0?.lowerBound }.min() ?? rest.endIndex
    return String(xml[start.lowerBound..<end])
}

/// AI 那一半：AI 只能改自己的表，所以都在 copy_from 出来的副本上试。
@MainActor
func lockedFormulaAIChecks() {
    func open(_ data: Data) throws -> (WorkbookDocument, SheetSession, Int) {
        let session = SheetSession(workbook: try XLSXReader.read(data))
        let document = WorkbookDocument()
        document.session = session
        NSDocumentController.shared.addDocument(document)
        AIWorkbooks.makeCurrent(document)
        _ = try AIWriteTools.addSheet(AIToolArguments(["name": "Copy", "copy_from": "Data"]))
        return (document, session, session.workbook.sheets.firstIndex { $0.name == "Copy" } ?? 0)
    }
    func refused(_ what: String, _ session: SheetSession, _ call: () throws -> Void) {
        let workbook = session.workbook, revision = session.revision
        do {
            try call()
            fail("\(what): went through")
        } catch is AIToolError {
        } catch {
            fail("\(what): unexpected \(error)")
        }
        check(session.workbook == workbook && session.revision == revision, "\(what): nothing changed")
    }

    group("ui-ai-5: the AI can't change locked formula cells in its copies") {
        let (shared, sharedSession, sharedCopy) = try open(try sharedFormulaLockWorkbook())
        let sharedContext = AIContext(document: shared, session: sharedSession)
        refused("the copy's B1", sharedSession) {
            try sharedContext.change("AI step") { $0.enter(.number(7, format: nil), at: CellAddress(a1: "B1")!, sheet: sharedCopy) }
        }
        NSDocumentController.shared.removeDocument(shared)

        let (table, tableSession, tableCopy) = try open(try dataTableLockWorkbook())
        let tableContext = AIContext(document: table, session: tableSession)
        refused("the copy's H3", tableSession) {
            try tableContext.change("AI step") { $0.enter(.number(99, format: nil), at: CellAddress(a1: "H3")!, sheet: tableCopy) }
        }
        refused("a row inserted in the copy", tableSession) {
            _ = try AIRowColumnTools.edit(AIToolArguments(["sheet": "Copy", "rows": "10", "insert": true]))
        }
        NSDocumentController.shared.removeDocument(table)
    }
}

/// B1:B3 的主公式 `A1+Inputs!Rate`：带 sheet 名的定义名称切不了词，A1 又会平移，跟随者的公式算不出来（审查第 3 条的例子）。
private func sharedFormulaLockWorkbook() throws -> Data {
    try namespacedPackage(sheetBody: """
        <sheetData><row r="1"><c r="A1"><v>1</v></c><c r="B1"><f t="shared" ref="B1:B3" si="0">A1+Inputs!Rate</f><v>2</v></c></row>\
        <row r="2"><c r="A2"><v>2</v></c><c r="B2"><f t="shared" si="0"/><v>3</v></c></row>\
        <row r="3"><c r="A3"><v>3</v></c><c r="B3"><f t="shared" si="0"/><v>4</v></c></row></sheetData>
        """)
}

/// 单变量模拟运算表：输入格 J1，公式行 H1，代入值 G2:G3，结果 H2:H3（审查第 5 条的例子）。
private func dataTableLockWorkbook() throws -> Data {
    try namespacedPackage(sheetBody: """
        <sheetData><row r="1"><c r="H1"><f>J1*2</f><v>2</v></c><c r="J1"><v>1</v></c></row>\
        <row r="2"><c r="G2"><v>2</v></c><c r="H2"><f t="dataTable" ref="H2:H3" dt2D="0" dtr="0" r1="J1"/><v>4</v></c></row>\
        <row r="3"><c r="G3"><v>3</v></c><c r="H3"><v>6</v></c></row></sheetData>
        """)
}

/// 两组算不出来的共享公式：B1:B2（`A1+Inputs!Rate`）和 D1:D2（`C1+Inputs!Rate`），第二轮审查的例子。
private func twoUnknownGroupsWorkbook() throws -> Data {
    try namespacedPackage(sheetBody: """
        <sheetData><row r="1"><c r="A1"><v>1</v></c><c r="B1"><f t="shared" ref="B1:B2" si="0">A1+Inputs!Rate</f><v>2</v></c>\
        <c r="C1"><v>5</v></c><c r="D1"><f t="shared" ref="D1:D2" si="1">C1+Inputs!Rate</f><v>6</v></c></row>\
        <row r="2"><c r="A2"><v>2</v></c><c r="B2"><f t="shared" si="0"/><v>3</v></c>\
        <c r="C2"><v>6</v></c><c r="D2"><f t="shared" si="1"/><v>7</v></c></row></sheetData>
        """)
}

/// 主式只有带 sheet 名的定义名称和小写的绝对引用：`Sheet1!Rate*$a$1`（第二轮审查第 1 条的例子）。
private func namesOnlyWorkbook() throws -> Data {
    try namespacedPackage(sheetBody: """
        <sheetData><row r="1"><c r="B1"><f t="shared" ref="B1:B2" si="0">Sheet1!Rate*$a$1</f><v>2</v></c></row>\
        <row r="2"><c r="B2"><f t="shared" si="0"/><v>2</v></c></row></sheetData>
        """)
}
