import Foundation
import SkySheetCore
import SkySheetFiles

@MainActor
func sharedWorkbookChecks() {
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
