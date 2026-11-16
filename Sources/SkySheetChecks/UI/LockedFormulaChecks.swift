import AppKit
import SkySheetCore
import SkySheetFiles

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
        let before = session.workbook
        type(session, 7, at: "B1")
        check(session.workbook == before, "typing over B1 is refused")
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
        let before = session.workbook
        type(session, 99, at: "H3")
        check(session.workbook == before, "a result cell is refused (Excel: Cannot change part of a data table)")
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

/// AI 那一半：AI 只能改自己的表，所以都在 copy_from 出来的副本上试。
@MainActor
func lockedFormulaAIChecks() {
    func open(_ data: Data) throws -> (WorkbookDocument, SheetSession, Int) {
        let session = SheetSession(workbook: try XLSXReader.read(data))
        session.undoManager = UndoManager()
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
