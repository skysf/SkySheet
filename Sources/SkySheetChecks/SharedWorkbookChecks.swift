import Foundation
import SkySheetCore
import SkySheetFiles

@MainActor
func sharedWorkbookChecks() {
    group("autosave: every edit survives reopening, including intermediate and restored versions") {
        let folder = try makeTemporaryDirectory()
        let url = folder.appendingPathComponent("Steps.xlsx")
        try FileManager.default.copyItem(at: fixtureURL("IronCalc/arithmetic.xlsx"), to: url)
        let opened = try LoadedWorkbook(contentsOf: url)
        let history = WorkbookHistory(file: url, root: folder.appendingPathComponent("History"))
        let backups = BackupStore(root: folder.appendingPathComponent("Backups"))
        let writer = WorkbookAutosave(url: url, loaded: opened, history: history, backups: backups)
        let address = CellAddress(row: 0, column: 0)
        var workbook = opened.workbook
        for number in [17, 42] {
            workbook.enter(.value(.number(Decimal(number))), at: address, sheet: 0)
            Recalculator.recalculate(&workbook)
            writer.submit(.init("Edit \(number)", workbook: workbook, source: opened.source, baseline: opened.workbook)) { _ in }
        }
        if let error = writer.flush()?.error { throw error }
        checkEqual(try LoadedWorkbook(contentsOf: url).workbook.sheets[0].cells[address]?.value, .number(42), "saved without a manual save")
        let reopenedHistory = WorkbookHistory(file: url, root: folder.appendingPathComponent("History"))
        let versions = try reopenedHistory.versions()
        checkEqual(versions.map(\.title), ["Edit 42", "Edit 17", "Opened Version"], "each committed operation in order")
        guard versions.count == 3 else { return }
        let earlier = try reopenedHistory.load(versions[1])
        checkEqual(earlier.workbook.sheets[0].cells[address]?.value, .number(17), "intermediate version")
        writer.submit(.init("Restore", workbook: earlier.workbook, source: earlier.source, baseline: earlier.workbook)) { _ in }
        if let error = writer.flush()?.error { throw error }
        checkEqual(try LoadedWorkbook(contentsOf: url).workbook.sheets[0].cells[address]?.value, .number(17), "restored workbook on disk")
        checkEqual(try history.versions().count, 4, "restoring also keeps later steps")
        checkEqual(backups.backups(of: url).count, 1, "one backup per open session")
        checkEqual(try Data(contentsOf: backups.backups(of: url)[0]), opened.originalData, "exact original backup")
        let external = Data("externally replaced".utf8)
        try external.write(to: url, options: .atomic)
        writer.submit(.init("Concurrent edit", workbook: workbook, source: opened.source, baseline: opened.workbook)) { _ in }
        check(writer.flush()?.error is WorkbookAutosave.Issue, "external edits are reported")
        checkEqual(try Data(contentsOf: url), external, "external edit survives")
        checkEqual(try history.versions().first?.title, "Concurrent edit", "local edit saved in history despite conflict")
    }

    group("autosave: CSV preserves its format and keeps formulas available on reopen") {
        let folder = try makeTemporaryDirectory()
        let url = folder.appendingPathComponent("Amounts.tsv")
        try Data("4\t8\r\n".utf8).write(to: url)
        let opened = try LoadedWorkbook(contentsOf: url)
        var workbook = opened.workbook
        workbook.enter(.formula("A1*3"), at: CellAddress(row: 0, column: 1), sheet: 0)
        Recalculator.recalculate(&workbook)
        let history = WorkbookHistory(file: url, root: folder.appendingPathComponent("History"))
        let writer = WorkbookAutosave(url: url, loaded: opened, history: history, backups: BackupStore(root: folder.appendingPathComponent("Backup")))
        writer.submit(.init("Formula", workbook: workbook, source: nil, baseline: opened.workbook)) { _ in }
        if let error = writer.flush()?.error { throw error }
        let data = try Data(contentsOf: url)
        checkEqual(String(decoding: data, as: UTF8.self), "4\t12\r\n", "TSV on disk contains the result and original line ending")
        let reopened = try LoadedWorkbook(data: data, url: url, history: history)
        checkEqual(reopened.workbook.sheets[0].cells[0, 1]?.formula?.source, "A1*3", "formula restored on reopening TSV")
        let replaced = try LoadedWorkbook(data: Data("7\t21\r\n".utf8), url: url, history: history)
        check(replaced.workbook.sheets[0].cells[0, 1]?.formula == nil, "external file takes precedence over local history")
    }
    group("shared workbook: IronCalc spreadsheet and verified save") {
        let loaded = try LoadedWorkbook(contentsOf: fixtureURL("IronCalc/arithmetic.xlsx"))
        var workbook = loaded.workbook
        guard let sheet = workbook.sheetIndex(named: "Sheet1") else { return fail("missing Sheet1") }
        let sum = CellAddress(row: 1, column: 4)
        checkEqual(workbook.sheets[sheet].cells[sum]?.formula?.cachedValue, .number(3), "Excel cached value")
        checkEqual(workbook.sheets[sheet].cells[sum]?.value, .number(3), "shared loader recalculates E2")

        let index = try workbook.addSheet(named: "Calculation")
        let factor = CellAddress(row: 0, column: 0)
        let result = CellAddress(row: 0, column: 1)
        workbook.enter(.formula("Sheet1!E2*A1"), at: result, sheet: index)
        for value in [4, 8] {
            workbook.enter(.value(.number(Decimal(value))), at: factor, sheet: index)
            Recalculator.recalculate(&workbook, options: .init(cache: loaded.recalcCache))
            checkEqual(workbook.sheets[index].cells[result]?.value, .number(Decimal(3 * value)), "recalculated product")
        }
        let output = try makeTemporaryDirectory().appendingPathComponent("RoundTrip.xlsx")
        let written = try XLSXWriter.write(workbook, source: loaded.source, baseline: loaded.workbook)
        try NewFile.write(written.data, to: output)
        _ = try SaveVerifier.verify(Data(contentsOf: output), written: written, workbook: workbook, source: loaded.source)
        let reopened = try LoadedWorkbook(contentsOf: output)
        guard let reopenedSheet = reopened.workbook.sheetIndex(named: "Calculation") else { return fail("missing Calculation") }
        let cell = reopened.workbook.sheets[reopenedSheet].cells[result]
        checkEqual(cell?.formula?.source, "Sheet1!E2*A1", "saved formula")
        checkEqual(cell?.value, .number(24), "saved and reopened product")
    }

    group("shared workbook: delimited text keeps its format on load") {
        let url = try makeTemporaryDirectory().appendingPathComponent("FromProvider")
        try NewFile.write(Data("Title\tAmount\r\nPaper\t12\r\n".utf8), to: url)
        let loaded = try LoadedWorkbook(contentsOf: url, typeName: "public.tab-separated-values-text")
        checkEqual(loaded.csvFormat?.delimiter, "\t", "file type takes precedence over missing extension")
        checkEqual(loaded.csvFormat?.lineEnding, "\r\n", "line ending")
        checkEqual(loaded.workbook.sheets.first?.cells[1, 1]?.value, .number(12), "numeric field")
    }

    group("numfmt: percentage and thousands scaling") {
        struct Example: Decodable { let format: String; let input: String; let expected: String }
        let data = try Data(contentsOf: fixtureURL("numfmt/scaling.json"))
        let examples = try JSONDecoder().decode([Example].self, from: data)
        checkEqual(examples.count, 3, "all examples from the upstream group")
        for example in examples {
            guard let value = DecimalMath.parse(example.input) else { return fail("invalid fixture decimal") }
            checkEqual(ValueFormatter.format(.number(value), code: example.format).text, example.expected,
                       "\(example.input) with \(example.format)")
        }
    }
}
