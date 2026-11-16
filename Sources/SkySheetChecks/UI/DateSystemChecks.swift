import Foundation
import SkySheetCore
import SkySheetFiles

@MainActor
func dateSystemPasteChecks() {
    group("ui-26: active sections and durations survive cross-system paste and save") {
        // 第三项：源值生效的那一段是不是日历日期。是日期而换算后落在 1904-01-01 之前的不换算（设计第十五节）。
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
        // 换算后常规格只留生效的日期段、去掉条件；单段格式本来就是它自己。
        let dateSections = ["[>=1]yyyy-mm-dd;0.0": "yyyy-mm-dd", "[>=1]0.0;yyyy-mm-dd": "yyyy-mm-dd",
                            "[>1]0.0;[<0]yyyy-mm-dd;0.0": "yyyy-mm-dd", "0.0;yyyy-mm-dd hh:mm": "yyyy-mm-dd hh:mm",
                            "0.0;0.0;yyyy-mm-dd": "yyyy-mm-dd"]
        let address = CellAddress(a1: "A1")!
        for system in [DateSystem.from1900, .from1904] {
            for (code, number, calendar) in cases {
                var sheet = Sheet(id: 1, name: "Main")
                let styles = StyleTable(customNumberFormats: [164: code], cellFormats: [CellFormat(), CellFormat(numberFormatID: 164)])
                sheet.cells[address] = Cell(value: .number(number), styleIndex: 1)
                let source = SheetSession(workbook: Workbook(sheets: [sheet], styles: styles, dateSystem: system))
                let clip = try JSONDecoder().decode(CellClip.self, from: JSONEncoder().encode(source.clipOfSelection()))
                let other: DateSystem = system == .from1900 ? .from1904 : .from1900
                let target = SheetSession(workbook: Workbook(sheets: [Sheet(id: 1, name: "Main")], dateSystem: other))
                try target.paste(clip)
                // 这些数从 1904 换到 1900 都还是真有的日子；1900 → 1904 时不到 1462 的落在 1904 纪元之前。
                let convert = calendar && (system == .from1904 || number >= 1462)
                let expected = CellValue.number(number + (convert ? (system == .from1900 ? -1462 : 1462) : 0))
                let expectedCode = convert ? dateSections[code] ?? code : code
                let context = "\(system) \(code) value \(number)"
                checkEqual(target.sheet.cells[address]?.value, expected, "paste \(context)")
                let saved = try XLSXReader.read(XLSXWriter.write(target.workbook, source: nil, baseline: nil).data)
                checkEqual(saved.sheets[0].cells[address]?.value, expected, "save/read \(context)")
                checkEqual(saved.styles.formatCode(forStyle: saved.sheets[0].cells[address]!.styleIndex), expectedCode,
                           "format survives \(context)")
                if convert {
                    checkEqual(ValueFormatter.format(expected, code: expectedCode, dateSystem: other).text,
                               ValueFormatter.format(.number(number), code: code, dateSystem: system).text,
                               "converted date keeps its day \(context)")
                }
                if !calendar {
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

    group("ui-28: cross-section dates keep their day in General targets and survive a round trip") {
        struct Case {
            let system: DateSystem
            let code: String
            let value: Decimal
            let shown: String
            let pasted: Decimal
            let pastedShown: String
            let back: Decimal
            let backShown: String
        }
        // 前八项是 PR #14 第三轮审查第二节的例子，最后两项是现代日期。目标系统里没有的日子（1904 纪元之前、
        // 1900-01-00、虚构的 1900-02-29）不换算、原样粘贴，显示和往返结果是设计第十五节写明的已知限制。
        let cases = [
            Case(system: .from1900, code: "[>=1]yyyy-mm-dd;0.0", value: 59, shown: "1900-02-28",
                 pasted: 59, pastedShown: "1904-02-29", back: 1521, backShown: "1904-02-29"),
            Case(system: .from1900, code: "[>=1]yyyy-mm-dd;0.0", value: 60, shown: "1900-02-29",
                 pasted: 60, pastedShown: "1904-03-01", back: 1522, backShown: "1904-03-01"),
            Case(system: .from1900, code: "[>=1]yyyy-mm-dd;0.0", value: 61, shown: "1900-03-01",
                 pasted: 61, pastedShown: "1904-03-02", back: 1523, backShown: "1904-03-02"),
            Case(system: .from1900, code: "[>=1]yyyy-mm-dd;0.0", value: 1461.5, shown: "1903-12-31",
                 pasted: 1461.5, pastedShown: "1908-01-01", back: 2923.5, backShown: "1908-01-01"),
            Case(system: .from1904, code: "0.0;yyyy-mm-dd", value: -1462, shown: "1900-01-00",
                 pasted: -1462, pastedShown: "########", back: -1462, backShown: "1900-01-00"),
            Case(system: .from1904, code: "0.0;yyyy-mm-dd", value: -1461.5, shown: "1900-01-00",
                 pasted: -1461.5, pastedShown: "########", back: -1461.5, backShown: "1900-01-00"),
            Case(system: .from1904, code: "0.0;yyyy-mm-dd", value: -1.5, shown: "1903-12-30",
                 pasted: 1460.5, pastedShown: "1903-12-30", back: 1460.5, backShown: "1907-12-31"),
            Case(system: .from1904, code: "0.0;yyyy-mm-dd", value: -0.5, shown: "1903-12-31",
                 pasted: 1461.5, pastedShown: "1903-12-31", back: 1461.5, backShown: "1908-01-01"),
            Case(system: .from1900, code: "[>=45000]yyyy-mm-dd;0.0", value: 45000, shown: "2023-03-15",
                 pasted: 43538, pastedShown: "2023-03-15", back: 45000, backShown: "2023-03-15"),
            Case(system: .from1904, code: "[>=50000]0.0;[Blue]\"Day \"yyyy-mm-dd", value: 43538, shown: "Day 2023-03-15",
                 pasted: 45000, pastedShown: "Day 2023-03-15", back: 43538, backShown: "Day 2023-03-15")
        ]
        let address = CellAddress(a1: "A1")!
        @MainActor func display(_ session: SheetSession) -> FormattedValue {
            let cell = session.sheet.cells[address] ?? Cell()
            return ValueFormatter.format(cell.value, code: session.workbook.styles.formatCode(forStyle: cell.styleIndex),
                                         dateSystem: session.workbook.dateSystem)
        }
        @MainActor func blank(_ system: DateSystem) -> SheetSession {
            SheetSession(workbook: Workbook(sheets: [Sheet(id: 1, name: "Main")], dateSystem: system))
        }
        for item in cases {
            let other: DateSystem = item.system == .from1900 ? .from1904 : .from1900
            var sheet = Sheet(id: 1, name: "Main")
            sheet.cells[address] = Cell(value: .number(item.value), styleIndex: 1)
            let styles = StyleTable(customNumberFormats: [164: item.code], cellFormats: [CellFormat(), CellFormat(numberFormatID: 164)])
            let source = SheetSession(workbook: Workbook(sheets: [sheet], styles: styles, dateSystem: item.system))
            let context = "\(item.system) \(item.code) value \(item.value)"
            checkEqual(display(source).text, item.shown, "source display \(context)")
            let target = blank(other)
            try target.paste(JSONDecoder().decode(CellClip.self, from: JSONEncoder().encode(source.clipOfSelection())))
            checkEqual(target.sheet.cells[address]?.value, .number(item.pasted), "pasted serial \(context)")
            checkEqual(display(target).text, item.pastedShown, "pasted display \(context)")
            // 保存再读回来还是同一天，再从读回的那份复制回源日期系统。
            let reloaded = try SheetSession(workbook: XLSXReader.read(XLSXWriter.write(target.workbook, source: nil, baseline: nil).data))
            checkEqual(display(reloaded).text, item.pastedShown, "saved display \(context)")
            let back = blank(item.system)
            try back.paste(reloaded.clipOfSelection())
            checkEqual(back.sheet.cells[address]?.value, .number(item.back), "round-trip serial \(context)")
            checkEqual(display(back).text, item.backShown, "round-trip display \(context)")
        }
        // 颜色、引号里的文字跟着日期段走，条件去掉。
        var sheet = Sheet(id: 1, name: "Main")
        sheet.cells[address] = Cell(value: .number(45000), styleIndex: 1)
        let styles = StyleTable(customNumberFormats: [164: "[Red][>=45000]yyyy-mm-dd;0.0"],
                                cellFormats: [CellFormat(), CellFormat(numberFormatID: 164)])
        let source = SheetSession(workbook: Workbook(sheets: [sheet], styles: styles, dateSystem: .from1900))
        let target = blank(.from1904)
        try target.paste(source.clipOfSelection())
        checkEqual(target.workbook.styles.formatCode(forStyle: target.sheet.cells[address]!.styleIndex), "[Red]yyyy-mm-dd",
                   "General target keeps only the active date section with its color")
        checkEqual(display(target), FormattedValue(text: "2023-03-15", color: .named("Red")), "colored date display")

        // 目标格不是常规：照旧换算数值，格子自己的格式不动。
        var formatted = Sheet(id: 1, name: "Main")
        formatted.cells[address] = Cell(styleIndex: 1)
        let numberTarget = SheetSession(workbook: Workbook(sheets: [formatted],
                                                           styles: StyleTable(cellFormats: [CellFormat(), CellFormat(numberFormatID: 2)]),
                                                           dateSystem: .from1904))
        try numberTarget.paste(source.clipOfSelection())
        checkEqual(numberTarget.sheet.cells[address]?.value, .number(43538), "non-General target still converts")
        checkEqual(numberTarget.workbook.styles.formatCode(forStyle: numberTarget.sheet.cells[address]!.styleIndex), "0.00",
                   "non-General target keeps its own format")
    }
}
