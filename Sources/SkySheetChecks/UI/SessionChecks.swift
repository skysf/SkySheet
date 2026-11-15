import AppKit
import SkySheetCore
import SkySheetDisplay
@testable import SkySheet

@MainActor
func sessionEditingChecks() {
    group("ui-1: internal clipboard preserves CellValue") {
        var sheet = Sheet(id: 1, name: "Main")
        let values: [CellValue] = [.number(Decimal(string: "123456789012345.6")!), .number(0.5),
                                 .error(.na), .bool(true), .text("00123"), .text("=A1"), .empty,
                                 .error(.circular), .error(.other("#SPILL!")),
                                 .number(Decimal(string: "12345678901234567890.123456789012345678")!)]
        for (row, value) in values.enumerated() {
            sheet.cells[CellAddress(row: row, column: 0)] = Cell(value: value, styleIndex: row == 1 ? 1 : 0)
        }
        let styles = StyleTable(cellFormats: [CellFormat(), CellFormat(numberFormatID: 20)])
        let session = SheetSession(workbook: Workbook(sheets: [sheet], styles: styles))
        session.select(CellRange(a1: "A1:A10")!)
        let encoded = try JSONEncoder().encode(session.clipOfSelection())
        let clip = try JSONDecoder().decode(CellClip.self, from: encoded)
        session.select(CellAddress(a1: "B1")!)
        session.paste(clip)
        for (row, value) in values.enumerated() {
            checkEqual(session.sheet.cells[CellAddress(row: row, column: 1)]?.value ?? .empty, value, "typed row \(row + 1)")
        }
    }
    group("ui-2: 1904 formula bar and clipboard") {
        var sheet = Sheet(id: 1, name: "Main")
        sheet.cells[CellAddress(a1: "A1")!] = Cell(value: .number(45000))
        let styles = StyleTable(cellFormats: [CellFormat(numberFormatID: 14)])
        let session = SheetSession(workbook: Workbook(sheets: [sheet], styles: styles, dateSystem: .from1904))
        checkEqual(session.rawText(at: CellAddress(a1: "A1")!), "2027/3/16", "formula bar uses workbook date system")
        let clip = try JSONDecoder().decode(CellClip.self, from: JSONEncoder().encode(session.clipOfSelection()))
        checkEqual(clip.dateSystem, .from1904, "clipboard retains source date system")
        session.select(CellAddress(a1: "B1")!)
        session.paste(clip)
        checkEqual(session.sheet.cells[CellAddress(a1: "B1")!]?.value, .number(45000), "1904 serial survives copy")
    }
    group("ui-1: typed fill and formula references") {
        var sheet = Sheet(id: 1, name: "Main")
        let a1 = CellAddress(a1: "A1")!
        let number = Decimal(string: "123456789012345.6")!
        sheet.cells[a1] = Cell(value: .number(number))
        let session = SheetSession(workbook: Workbook(sheets: [sheet]))
        let clip = try session.clipOfSelection()
        session.select(CellRange(a1: "B2:C3")!)
        session.paste(clip)
        for address in ["B2", "C2", "B3", "C3"] {
            checkEqual(session.sheet.cells[CellAddress(a1: address)!]?.value, .number(number), "typed fill \(address)")
        }
        session.select(a1)
        session.apply("Formula") { $0.sheets[0].cells[a1] = Cell(value: .number(9), formula: CellFormula(source: "UNKNOWN(B1)", cachedValue: .number(9))) }
        let formula = try session.clipOfSelection()
        session.select(CellAddress(a1: "B1")!)
        session.paste(formula)
        checkEqual(session.sheet.cells[CellAddress(a1: "B1")!]?.formula?.source, "UNKNOWN(C1)", "relative formula shifts")
        checkEqual(session.sheet.cells[CellAddress(a1: "B1")!]?.value, .number(9), "unsupported formula retains cached value")
        session.select(a1)
        session.beginEditing(.typing, text: "committed")
        let editingClip = try session.clipOfSelection()
        checkEqual(editingClip.rows[0][0].value, .text("committed"), "copy commits pending editing before collecting values")
    }
    group("ui-3: commit editing before sheet operations") {
        let workbook = Workbook(sheets: [Sheet(id: 1, name: "Main"), Sheet(id: 2, name: "Other")])
        let a1 = CellAddress(a1: "A1")!
        for source in [0, 1] {
            let session = SheetSession(workbook: workbook)
            session.beginEditing(.typing, text: "new")
            session.duplicateSheet(source)
            session.commitEditing()
            checkEqual(session.workbook.sheets[0].cells[a1]?.value, .text("new"), "original edit committed before duplicate")
            checkEqual(session.sheet.cells[a1]?.value, source == 0 ? .text("new") : nil, "copy sees committed source only")
            check(session.editing == nil, "duplicate ends pending editing")
        }
        let session = SheetSession(workbook: workbook)
        session.beginEditing(.typing, text: "new")
        try session.deleteSheet(0)
        session.commitEditing()
        checkEqual(session.sheet.cells[a1]?.value, nil, "delete never transfers pending edit to successor")
        let switching = SheetSession(workbook: workbook)
        switching.beginEditing(.typing, text: "new")
        switching.showSheet(1)
        checkEqual(switching.workbook.sheets[0].cells[a1]?.value, .text("new"), "switch commits to original")
        checkEqual(switching.sheet.cells[a1]?.value, nil, "switch target stays empty")
    }
}

@MainActor
func copyLimitChecks() {
    group("ui-5: reject sparse rectangle before allocation") {
        var sheet = Sheet(id: 1, name: "Sparse")
        sheet.cells[CellAddress(a1: "A1")!] = Cell(value: .number(1))
        sheet.cells[CellAddress(a1: "XFD1048576")!] = Cell(value: .number(2))
        let session = SheetSession(workbook: Workbook(sheets: [sheet]))
        session.selectAll()
        // 只调两个复制入口共用的预检，不调会密集展开的路径。
        var refused = false
        do { _ = try session.checkedCopyRange() } catch { refused = true }
        check(refused, "17,179,869,184 cells must be refused before any rectangular allocation")
        session.select(CellRange(a1: "A1:J100000")!)
        checkEqual(try session.checkedCopyRange(), CellRange(a1: "A1:J100000")!, "one million is accepted at boundary")
        session.select(CellRange(a1: "A1:K100000")!)
        refused = false
        do { _ = try session.checkedCopyRange() } catch { refused = true }
        check(refused, "above one million is refused")
    }
}

@MainActor
func sizeLocaleChecks() {
    group("ui-10: localized size defaults round trip") {
        for locale in ["en_US", "de_DE", "fr_FR"] {
            let input = SizeInput(locale: Locale(identifier: locale))
            for value in [0.0, 8.43, 15.0, 255.0, 409.0] {
                checkEqual(input.value(input.string(value)), value, "\(locale) accepts its default \(value)")
            }
            checkEqual(input.value("garbage"), nil, "invalid input rejected")
            checkEqual(input.value(input.string(8.43) + "abc"), nil, "trailing garbage rejected")
            checkEqual(input.value(""), nil, "empty input rejected")
        }
    }
}
