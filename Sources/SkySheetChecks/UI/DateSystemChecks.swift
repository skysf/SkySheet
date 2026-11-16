import Foundation
import SkySheetCore
import SkySheetFiles

@MainActor
func dateSystemPasteChecks() {
    group("ui-26: active sections and durations survive cross-system paste and save") {
        let cases: [(String, Decimal, Bool)] = [
            ("[>=1]yyyy-mm-dd;0.0", 0.5, false),
            ("[>=1]yyyy-mm-dd;0.0", 1, true),
            ("[>1]yyyy-mm-dd;0.0", 1, false),
            ("[>=1]yyyy-mm-dd;0.0", 45000, true),
            ("[>=1]0.0;yyyy-mm-dd", 0.5, true),
            ("[>=1]0.0;yyyy-mm-dd", 45000, false),
            ("[>1]0.0;[<0]yyyy-mm-dd;0.0", -0.5, true),
            ("[>1]yyyy-mm-dd;[<0]0.0;0.0", -0.5, false),
            ("0.0;yyyy-mm-dd hh:mm", -0.5, true),
            ("0.0;yyyy-mm-dd hh:mm", 0.5, false),
            ("yyyy-mm-dd;0.0;0.0", 0, false),
            ("0.0;0.0;yyyy-mm-dd", 0, true),
            ("yyyy-mm-dd;0.0", -0.5, false),
            ("yyyy-mm-dd h:mm", 45000.5, true),
            ("mmm", 45000, true),
            ("ddd", 45000, true),
            ("yyyy-mm-dd", 59, true), ("yyyy-mm-dd", 60, true), ("yyyy-mm-dd", 61, true),
            ("[h]:mm", 0.5, false), ("[m]:ss", 0.5, false), ("[s]", 0.5, false),
            ("[hh]:mm:ss", 1.5, false), ("[mm]:ss", 1.5, false), ("[ss]", 1.5, false),
            ("h:mm", 0.5, false), ("h:mm", 1.5, false), ("mm:ss", 0.5, false),
            ("h:mm AM/PM", 0.5, false),
            ("[>=1]yyyy-mm-dd;[h]:mm", 0.5, false),
            ("[>=1][h]:mm;yyyy-mm-dd", 45000, false),
            ("0.0\"yyyy-mm-dd\"", 0.5, false),
            ("0.0;0.0;\"yyyy-mm-dd\"", 0, false)
        ]
        let address = CellAddress(a1: "A1")!
        for system in [DateSystem.from1900, .from1904] {
            for (code, number, convert) in cases {
                var sheet = Sheet(id: 1, name: "Main")
                let styles = StyleTable(customNumberFormats: [164: code], cellFormats: [CellFormat(), CellFormat(numberFormatID: 164)])
                sheet.cells[address] = Cell(value: .number(number), styleIndex: 1)
                let source = SheetSession(workbook: Workbook(sheets: [sheet], styles: styles, dateSystem: system))
                let clip = try JSONDecoder().decode(CellClip.self, from: JSONEncoder().encode(source.clipOfSelection()))
                let other: DateSystem = system == .from1900 ? .from1904 : .from1900
                let target = SheetSession(workbook: Workbook(sheets: [Sheet(id: 1, name: "Main")], dateSystem: other))
                try target.paste(clip)
                let expected = CellValue.number(number + (convert ? (system == .from1900 ? -1462 : 1462) : 0))
                let context = "\(system) \(code) value \(number)"
                checkEqual(target.sheet.cells[address]?.value, expected, "paste \(context)")
                let saved = try XLSXReader.read(XLSXWriter.write(target.workbook, source: nil, baseline: nil).data)
                checkEqual(saved.sheets[0].cells[address]?.value, expected, "save/read \(context)")
                checkEqual(saved.styles.formatCode(forStyle: saved.sheets[0].cells[address]!.styleIndex), code, "format survives \(context)")
                if !convert {
                    checkEqual(source.rawText(at: address), ValueFormatter.general(number), "formula bar keeps non-calendar value \(context)")
                    checkEqual(ValueFormatter.format(expected, code: code, dateSystem: other).text,
                               ValueFormatter.format(.number(number), code: code, dateSystem: system).text, "non-calendar display stays stable \(context)")
                    if number == 0.5, let displayed = ["[>=1]yyyy-mm-dd;0.0": "0.5", "[h]:mm": "12:00", "[m]:ss": "720:00", "[s]": "43200"][code] {
                        checkEqual(ValueFormatter.format(saved.sheets[0].cells[address]!.value, code: code, dateSystem: other).text,
                                   displayed, "reviewer example keeps its concrete display after save \(context)")
                    }
                }
            }
        }
    }
}
