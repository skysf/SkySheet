import AppKit
import SkySheetCore
import SkySheetDisplay
import SkySheetFiles

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
        try session.paste(clip)
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
        try session.paste(clip)
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
        try session.paste(clip)
        for address in ["B2", "C2", "B3", "C3"] {
            checkEqual(session.sheet.cells[CellAddress(a1: address)!]?.value, .number(number), "typed fill \(address)")
        }
        session.select(a1)
        session.apply("Formula") { $0.sheets[0].cells[a1] = Cell(value: .number(9), formula: CellFormula(source: "UNKNOWN(B1)", cachedValue: .number(9))) }
        let formula = try session.clipOfSelection()
        session.select(CellAddress(a1: "B1")!)
        try session.paste(formula)
        checkEqual(session.sheet.cells[CellAddress(a1: "B1")!]?.formula?.source, "UNKNOWN(C1)", "relative formula shifts")
        checkEqual(session.sheet.cells[CellAddress(a1: "B1")!]?.value, .error(.name), "unsupported pasted formula has no stale cache")
        let saved = try XLSXReader.read(XLSXWriter.write(session.workbook, source: nil, baseline: nil).data)
        checkEqual(saved.sheets[0].cells[CellAddress(a1: "B1")!]?.value, .error(.name), "saved pasted formula never exports stale v")
        checkEqual(session.sheet.cells[a1]?.formula?.cachedValue, .number(9), "source file cache remains untouched")
        session.select(a1)
        session.beginEditing(.typing, text: "committed")
        let editingClip = try session.clipOfSelection()
        checkEqual(editingClip.entries[0].value, .text("committed"), "copy commits pending editing before collecting values")
    }
    group("ui-25: sparse holes retain row order at merged targets") {
        var sheet = Sheet(id: 1, name: "Main")
        sheet.cells[CellAddress(a1: "A1")!] = Cell(value: .number(1))
        sheet.merges = [CellRange(a1: "D1:E1")!]
        let session = SheetSession(workbook: Workbook(sheets: [sheet]))
        session.select(CellRange(a1: "A1:B1")!)
        let clip = try session.clipOfSelection()
        session.select(CellAddress(a1: "D1")!)
        try session.paste(clip)
        checkEqual(session.sheet.cells[CellAddress(a1: "D1")!]?.value ?? .empty, .empty, "trailing empty still clears the shared merge anchor")
    }
    group("ui-24: ragged external rows only replace supplied fields") {
        var sheet = Sheet(id: 1, name: "Main")
        sheet.cells[CellAddress(a1: "B2")!] = Cell(value: .text("keep"))
        let session = SheetSession(workbook: Workbook(sheets: [sheet]))
        try session.paste([["a", "b"], ["c"]], from: nil)
        checkEqual(session.sheet.cells[CellAddress(a1: "B2")!]?.value, .text("keep"), "omitted field is not an explicit empty field")
        session.select(CellAddress(a1: "A1")!)
        try session.paste([["a", "b"], ["c", ""]], from: nil)
        checkEqual(session.sheet.cells[CellAddress(a1: "B2")!]?.value ?? .empty, .empty, "explicit empty field clears target")
    }
    group("ui-23: defined-name formula follows fillDown") {
        var sheet = Sheet(id: 1, name: "Main")
        sheet.cells[CellAddress(a1: "A1")!] = Cell(value: .number(100))
        sheet.cells[CellAddress(a1: "A2")!] = Cell(value: .number(200))
        sheet.cells[CellAddress(a1: "B1")!] = Cell(value: .number(5), formula: CellFormula(source: "A1*Rate", cachedValue: .number(5)))
        let session = SheetSession(workbook: Workbook(sheets: [sheet], definedNames: [DefinedName(name: "Rate", formula: "Main!$D$1")]))
        session.select(CellAddress(a1: "B1")!)
        let clip = try session.clipOfSelection()
        session.select(CellAddress(a1: "B2")!)
        try session.paste(clip)
        checkEqual(session.sheet.cells[CellAddress(a1: "B2")!]?.formula?.source, "A2*Rate", "defined-name formula shifts relative reference")
        checkEqual(session.sheet.cells[CellAddress(a1: "B2")!]?.value, .error(.name), "defined name cannot inherit stale source result")
    }
    group("ui-21: sparse paste clears holes and preserves rectangle") {
        var sheet = Sheet(id: 1, name: "Main")
        sheet.cells[CellAddress(a1: "A1")!] = Cell(value: .number(1))
        sheet.cells[CellAddress(a1: "B2")!] = Cell(value: .number(2))
        for a1 in ["D1", "E1", "D2", "E2"] { sheet.cells[CellAddress(a1: a1)!] = Cell(value: .text("old")) }
        let session = SheetSession(workbook: Workbook(sheets: [sheet]))
        session.select(CellRange(a1: "A1:B2")!)
        let clip = try session.clipOfSelection()
        checkEqual(clip.entries.count, 2, "holes are absent from JSON records")
        session.select(CellAddress(a1: "D1")!)
        try session.paste(clip)
        checkEqual(session.selection.range, CellRange(a1: "D1:E2")!, "sparse rectangle controls resulting selection")
        checkEqual(session.sheet.cells[CellAddress(a1: "E1")!]?.value ?? .empty, .empty, "top hole clears old target")
        checkEqual(session.sheet.cells[CellAddress(a1: "D2")!]?.value ?? .empty, .empty, "bottom hole clears old target")
        checkEqual(session.sheet.cells[CellAddress(a1: "E2")!]?.value, .number(2), "last nonempty cell keeps its offset")
    }
    group("ui-20: close commits a document's only pending change") {
        let session = SheetSession(workbook: Workbook(sheets: [Sheet(id: 1, name: "Main")]))
        let document = WorkbookDocument()
        document.session = session
        session.undoManager = document.undoManager
        session.beginEditing(.typing, text: "only pending input")
        checkEqual(session.revision, 0, "pending input has not dirtied the workbook yet")
        // 只关闭测试自己创建的无窗口文档，不启动 App、恢复流程或保存对话框。
        document.close()
        checkEqual(session.sheet.cells[CellAddress(a1: "A1")!]?.value, .text("only pending input"), "close commits before disposal")
        check(session.editing == nil, "close ends pending edit")
    }
    group("ui-14: dates and times retain formats only on General") {
        let table = StyleTable(cellFormats: [CellFormat(), CellFormat(numberFormatID: 14), CellFormat(numberFormatID: 22), CellFormat(numberFormatID: 20), CellFormat(numberFormatID: 2)])
        var sheet = Sheet(id: 1, name: "Main")
        for (row, value) in [Decimal(45000), Decimal(string: "45000.5")!, Decimal(string: "0.5")!].enumerated() {
            sheet.cells[CellAddress(row: row, column: 0)] = Cell(value: .number(value), styleIndex: row + 1)
            sheet.cells[CellAddress(row: row, column: 2)] = Cell(styleIndex: 4)
        }
        let session = SheetSession(workbook: Workbook(sheets: [sheet], styles: table))
        session.select(CellRange(a1: "A1:A3")!)
        let clip = try JSONDecoder().decode(CellClip.self, from: JSONEncoder().encode(session.clipOfSelection()))
        for column in [1, 2] {
            session.select(CellAddress(row: 0, column: column))
            try session.paste(clip)
            for row in 0..<3 {
                let source = session.sheet.cells[CellAddress(row: row, column: 0)]!
                let target = session.sheet.cells[CellAddress(row: row, column: column)]!
                checkEqual(target.value, source.value, "date/time numeric type survives")
                checkEqual(session.workbook.styles.formatCode(forStyle: target.styleIndex), column == 1 ? table.formatCode(forStyle: source.styleIndex) : table.formatCode(forStyle: 4), "date/time format follows General rule")
            }
        }
    }
    group("ui-15: date systems convert in both directions") {
        for sourceSystem in [DateSystem.from1900, .from1904] {
            let targetSystem: DateSystem = sourceSystem == .from1900 ? .from1904 : .from1900
            let table = StyleTable(cellFormats: [CellFormat(), CellFormat(numberFormatID: 14), CellFormat(numberFormatID: 22), CellFormat(numberFormatID: 20)])
            var sheet = Sheet(id: 1, name: "Main")
            for row in 0..<4 { sheet.cells[CellAddress(row: row, column: 0)] = Cell(value: .number(row == 3 ? Decimal(string: "0.5")! : row == 1 ? Decimal(string: "61.5")! : Decimal(string: "45000.5")!), styleIndex: row) }
            let source = SheetSession(workbook: Workbook(sheets: [sheet], styles: table, dateSystem: sourceSystem))
            source.select(CellRange(a1: "A1:A4")!)
            let clip = try JSONDecoder().decode(CellClip.self, from: JSONEncoder().encode(source.clipOfSelection()))
            let target = SheetSession(workbook: Workbook(sheets: [Sheet(id: 1, name: "Main")], dateSystem: targetSystem))
            try target.paste(clip)
            for row in 0..<4 {
                let cell = target.sheet.cells[CellAddress(row: row, column: 0)]!
                let sourceValue = row == 3 ? Decimal(string: "0.5")! : row == 1 ? Decimal(string: "61.5")! : Decimal(string: "45000.5")!
                // 1900 的 61.5（1900-03-01）落在 1904 纪元之前：不换算，原样粘贴（设计第十五节）。
                let early = row == 1 && sourceSystem == .from1900
                let expected = sourceValue + (row == 0 || row == 3 || early ? 0 : sourceSystem == .from1900 ? -1462 : 1462)
                checkEqual(cell.value, .number(expected), "serial converted only for calendar date/time formats")
                if row > 0, !early {
                    let code = table.formatCode(forStyle: row)
                    checkEqual(ValueFormatter.format(cell.value, code: code, dateSystem: targetSystem).text, ValueFormatter.format(.number(sourceValue), code: code, dateSystem: sourceSystem).text, "displayed day/time survives cross-system paste")
                }
            }
        }
    }
    group("ui-16: AI deletion cannot redirect an edit") {
        var original = Sheet(id: 1, name: "Main")
        original.cells[CellAddress(a1: "A1")!] = Cell(value: .text("original data"))
        let session = SheetSession(workbook: Workbook(sheets: [original, Sheet(id: 2, name: "AI result")]))
        session.showSheet(1)
        session.beginEditing(.typing, text: "pending")
        try session.apply("AI delete") { try $0.deleteSheet(1) }
        session.commitEditing()
        checkEqual(session.sheet.cells[CellAddress(a1: "A1")!]?.value, .text("original data"), "deleted editing sheet discards pending text")
        check(session.editing == nil, "deleted edit ends")
        // 表编号而非数组下标：删掉前面的表仍要写到原表。
        let reordered = SheetSession(workbook: Workbook(sheets: [original, Sheet(id: 2, name: "AI result")]))
        reordered.showSheet(1)
        reordered.beginEditing(.typing, text: "pending")
        try reordered.apply("AI delete preceding") { try $0.deleteSheet(0) }
        reordered.commitEditing()
        checkEqual(reordered.sheet.cells[CellAddress(a1: "A1")!]?.value, .text("pending"), "surviving sheet follows stable ID")
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
        // 走真实复制入口；稀疏编码下即使漏掉上限也不会分配巨大矩形。
        var refused = false
        do { _ = try session.clipOfSelection() } catch { refused = true }
        check(refused, "17,179,869,184 cells must be refused before any rectangular allocation")
        session.select(CellRange(a1: "A1:J100000")!)
        let boundary = try session.clipOfSelection()
        checkEqual(boundary.rowCount, 100000, "one million is accepted at boundary")
        checkEqual(boundary.columnCount, 10, "boundary retains rectangle width")
        checkEqual(boundary.entries.count, 1, "only nonempty cells are encoded")
        check(try JSONEncoder().encode(boundary).count < 1000, "one million mostly empty cells encode under 1 KB")
        session.select(CellRange(a1: "A1:K100000")!)
        refused = false
        do { _ = try session.clipOfSelection() } catch { refused = true }
        check(refused, "above one million is refused")
        session.select(CellRange(a1: "A1:B500001")!)
        let before = session.workbook
        refused = false
        do { try session.paste([["fill"]], from: nil) } catch { refused = true }
        check(refused, "single text cell cannot expand beyond copy limit")
        checkEqual(session.workbook, before, "rejected fill leaves workbook intact")
        let one = SheetSession(workbook: Workbook(sheets: [Sheet(id: 1, name: "Main")]))
        let clip = try one.clipOfSelection()
        refused = false
        do { try session.paste(clip) } catch { refused = true }
        check(refused, "single internal cell uses same fill limit")

    }
}

@MainActor
func sizeLocaleChecks() {
    group("ui-10: localized size defaults round trip") {
        for locale in ["en_US", "zh_CN", "de_DE", "fr_FR", "de_CH", "it_IT", "es_ES", "pt_BR", "ru_RU", "ar_SA", "hi_IN", "ja_JP"] {
            let input = SizeInput(locale: Locale(identifier: locale))
            for value in [0.0, 8.43, 15.0, 255.0, 409.0] {
                checkEqual(input.value(input.string(value)), value, "\(locale) accepts its default \(value)")
            }
            checkEqual(input.value("8.43"), 8.43, "\(locale) accepts decimal point")
            checkEqual(input.value("+5"), 5, "\(locale) accepts plus sign")
            checkEqual(input.value("garbage"), nil, "invalid input rejected")
            checkEqual(input.value(input.string(8.43) + "abc"), nil, "trailing garbage rejected")
            checkEqual(input.value(""), nil, "empty input rejected")
        }
        for locale in ["de_DE", "it_IT", "es_ES", "pt_BR"] {
            let input = SizeInput(locale: Locale(identifier: locale))
            for text in ["1.000", "1.234", "+1.000", "-1.000", "1.000e2", "1.000.000"] {
                checkEqual(input.value(text), nil, "\(locale) rejects ambiguous grouping \(text)")
            }
            checkEqual(input.value("1,000"), 1, "\(locale) accepts unambiguous local decimal")
            checkEqual(input.value("1000"), 1000, "plain thousands reaches range validation unchanged")
            checkEqual(input.value("8.1250"), 8.125, "unambiguous standard decimal remains supported")
        }
        checkEqual(SizeInput(locale: Locale(identifier: "en_US")).value("1.000"), 1, "period is unambiguous in US locale")
    }
}

@MainActor
func benchmarkModeChecks() {
    group("ui-18: historical scroll benchmark stays the default") {
        let args = ["SkySheet", "--benchmark", "synthetic:data", "--benchmark-only", "scroll", "--frames", "40"]
        checkEqual(BenchmarkRequest(arguments: args)?.cycleScroll, false, "historical scroll has no new cycling or warmup")
        checkEqual(BenchmarkRequest(arguments: args + ["--benchmark-cycle-scroll"])?.cycleScroll, true, "cycling is explicit")
    }
}

@MainActor
func sparseClipboardCostChecks() {
    group("ui-19: million-cell sparse clipboard cost") {
        var sheet = Sheet(id: 1, name: "Sparse")
        for row in 0..<100000 { sheet.cells[CellAddress(row: row, column: 0)] = Cell(value: .number(Decimal(row) + Decimal(string: "0.25")!)) }
        let session = SheetSession(workbook: Workbook(sheets: [sheet]))
        session.select(CellRange(a1: "A1:J100000")!)
        let clock = ContinuousClock(), start = clock.now
        let clip = try session.clipOfSelection()
        let clipped = clock.now
        let text = (0..<clip.rowCount).map { row in
            (0..<clip.columnCount).map { column -> String in
                let address = CellAddress(row: clip.originRow + row, column: clip.originColumn + column)
                guard let cell = session.sheet.cells[address] else { return "" }
                return CellDisplay.content(of: cell, style: session.styles.style(cell.styleIndex), dateSystem: session.workbook.dateSystem).text
            }.joined(separator: "\t")
        }.joined(separator: "\n")
        let texted = clock.now
        let data = try JSONEncoder().encode(clip)
        print("copy cost: clip \(clipped - start), TSV \(texted - clipped) (\(text.utf8.count) bytes), JSON \(clock.now - texted), \(data.count) bytes, \(clip.entries.count) entries")
        checkEqual(clip.entries.count, 100000, "100000 records for million-cell rectangle")
        check(data.count < 15000000, "sparse JSON stays below 15 MB")
    }
}
