import Foundation
import SkySheetCore
import SkySheetFiles
import SkyZip

/// 每个入口在独立进程里验证：一个坏公式不能让后面的复现丢掉，累计财务公式也必须有时间上限。
@MainActor
func formulaHuntChecks() {
    for name in ["irrErrors", "npvBooleans", "criteriaExtent", "blankCriterion", "gregorianToday",
                 "constantSumData", "rankOrder", "utf16Text", "subsecond15", "subsecond19", "subsecond100",
                 "lookupShape", "criteriaShape", "whitespaceInput", "largeDateExport", "cumulativeBound",
                 "dateOverflow", "dateMonthOverflow", "dateDayOverflow", "edateOverflow", "eomonthOverflow",
                 "serialOverflow", "inputTimeOverflow", "csvTimeOverflow", "dosCalendar", "fractionFormat", "horizontalSumData"] {
        group("formula hunt: \(name)") {
            let directory = try makeTemporaryDirectory()
            let log = directory.appendingPathComponent("output")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let output = try FileHandle(forWritingTo: log)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["--formula-hunt-case", name]
            process.standardOutput = output
            process.standardError = output
            var environment = ProcessInfo.processInfo.environment
            environment["SWIFT_BACKTRACE"] = "enable=no"
            process.environment = environment
            try process.run()
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            let timedOut = process.isRunning
            if timedOut { process.terminate() }
            process.waitUntilExit()
            try output.close()
            let details = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            check(!timedOut && process.terminationReason == .exit && process.terminationStatus == 0,
                  "\(name): \(timedOut ? "timeout" : "exit \(process.terminationStatus)")\n\(details.prefix(3000))")
        }
    }
}

@MainActor
func formulaHuntCase(_ name: String) {
    group("formula hunt: \(name)") {
        switch name {
        case "irrErrors":
            for (source, error) in [("=#N/A", CellError.na), ("=1/0", .div0)] {
                checkValue("IRR(A1:A3)", ["A1": "-100", "A2": source, "A3": "110"], .error(error))
            }
        case "npvBooleans":
            checkValue("NPV(100%,TRUE,4)", num("2"))
            checkValue("NPV(100%,FALSE,4)", num("2"))
        case "criteriaExtent":
            checkEqual(evaluate("COUNTIF(A1:A3,\"\")", ["A1": "1"], at: "B1"), num("2"), "explicit trailing blanks")
            checkEqual(evaluate("COUNTIF(A1:A3,\"\")", ["A1": "1", "D9": "x"], at: "B1"), num("2"), "unrelated content")
            checkEqual(evaluate("COUNTIF(A:A,\"\")", ["A1": "1"], at: "B1"), num("1048575"), "whole column blanks stay sparse")
            checkEqual(evaluate("COUNTIFS(A:A,\"\",B:B,\"\")", ["A1": "1", "B2": "2"], at: "C1"), num("1048574"), "union of occupied positions")
            checkEqual(evaluate("COUNTIF(Data!A:XFD,\"\")", at: "A1", otherSheets: ["Data": ["A1": "1"]]),
                       num("17179869183"), "whole sheet blanks stay sparse")
            checkEqual(evaluate("AVERAGEIF(A1:A3,\"\",B1:B3)", ["A1": "1", "B2": "4", "B3": "8"], at: "C1"), num("6"), "average over blank criteria")
        case "blankCriterion":
            checkEqual(evaluate("COUNTIFS(A1:A1,B1)", ["A1": "0"], at: "C1"), num("1"), "empty criterion reference is zero")
            checkValue("SUMIF(A1:A2,B1,C1:C2)", ["A1": "0", "A2": "2", "C1": "7", "C2": "8"], num("7"))
        case "gregorianToday":
            var buddhist = Calendar(identifier: .buddhist)
            buddhist.timeZone = TimeZone(secondsFromGMT: 28_800)!
            var gregorian = Calendar(identifier: .gregorian)
            gregorian.timeZone = buddhist.timeZone
            checkEqual(CivilDate.today(calendar: buddhist), CivilDate.today(calendar: gregorian), "calendar setting cannot change TODAY")
        case "constantSumData", "horizontalSumData":
            var workbook: Workbook
            if name == "constantSumData" {
                workbook = Workbook(sheets: [makeSheet("S", id: 1, ["A1": "项目", "B1": "金额", "A2": "甲",
                    "B2": "=SUM(1,2)", "A3": "乙", "B3": "=SUM(3,4)"])])
            } else {
                workbook = Workbook(sheets: [makeSheet("S", id: 1, ["A1": "Name", "B1": "Jan", "C1": "Feb", "D1": "Total",
                    "A2": "Alice", "B2": "1", "C2": "2", "D2": "=SUM(B2:C2)",
                    "A3": "Bob", "B3": "3", "C3": "4", "D3": "=SUM(B3:C3)"])])
            }
            Recalculator.recalculate(&workbook)
            let block = TableBlocks.find(in: workbook.sheets[0])[0]
            checkEqual(block.dataRows, 1...2, "both rows are data")
            checkEqual(block.totalsRow, nil, "data SUM is not a total")
            let rows = block.dataRows!
            let summary = ColumnSummary(column: 1, rows: rows, in: workbook.sheets[0], styles: workbook.styles, dateSystem: workbook.dateSystem)
            checkEqual(summary.count, 2, "describe_sheet includes both rows")
            checkEqual(summary.sum, name == "constantSumData" ? Decimal(10) : Decimal(4), "describe_sheet sum")
            let result = try SQLQuery.run("SELECT count(*), sum(\"\(name == "constantSumData" ? "金额" : "Jan")\") FROM S",
                                          tables: QueryTables.tables(for: workbook))
            checkEqual(result.rows[0], [.integer(2), .real(name == "constantSumData" ? 10 : 4)], "SQL includes both rows")
        case "rankOrder":
            for function in ["RANK", "RANK.EQ"] {
                for order in ["0.5", "-0.5"] {
                    checkValue("\(function)(2,A1:A2,\(order))", ["A1": "1", "A2": "2"], num("2"))
                }
            }
        case "utf16Text":
            checkValue("LEN(\"❤️\")", num("2"))
            checkValue("LEN(\"😀\")", num("2"))
            checkValue("MID(\"e\u{0301}X\",2,1)", .text("\u{0301}"))
            checkValue("LEFT(\"e\u{0301}X\",1)", .text("e"))
            checkValue("RIGHT(\"Xe\u{0301}\",1)", .text("\u{0301}"))
        case "subsecond15", "subsecond19", "subsecond100":
            let digits = Int(name.dropFirst("subsecond".count))!
            let code = "ss." + String(repeating: "0", count: digits)
            checkEqual(ValueFormatter.format(num("0"), code: code).text, "########", "unsupported second precision is safe")
            checkValue("TEXT(0,\"\(code)\")", .text("########"))
        case "lookupShape":
            checkValue("XLOOKUP(2,A1:A2,99)", ["A1": "1", "A2": "2"], .error(.value))
        case "criteriaShape":
            checkValue("COUNTIFS(A1:A2,\">0\",99,99)", ["A1": "1", "A2": "2"], .error(.value))
        case "whitespaceInput":
            for text in [" ", "   ", "\t", "\n"] {
                checkEqual(CellInput.parse(text), .value(.text(text)), "whitespace stays text")
            }
        case "largeDateExport":
            let number = Decimal(string: "1e20")!
            checkEqual(DateSerial.isoText(number, system: .from1900), nil, "large date has no ISO representation")
            var workbook = Workbook(sheets: [makeSheet("S", id: 1, ["A1": "日期", "B1": "备注", "A2": "1e20", "B2": "x"])])
            workbook.restyle(CellRange(a1: "A2")!, sheet: 0, Workbook.CellStyleChange(numberFormat: "yyyy/m/d"))
            let sheet = workbook.sheets[0]
            let csv = try CSVWriter.write(sheet, styles: workbook.styles, dateSystem: .from1900,
                                          format: CSVFormat(encoding: .utf8, hasByteOrderMark: false, delimiter: ",", lineEnding: "\n", endsWithLineBreak: true))
            check(String(decoding: csv.data, as: UTF8.self).contains("100000000000000000000"), "save CSV preserves number")
            let export = CSVWriter.analysisData(sheet, range: CellRange(a1: "A1:B2")!, styles: workbook.styles, dateSystem: .from1900)
            check(String(decoding: export, as: UTF8.self).contains("100000000000000000000"), "export_sheet preserves number")
            let query = try SQLQuery.run("SELECT \"日期\" FROM S", tables: QueryTables.tables(for: workbook))
            checkEqual(query.rows[0][0], .real(1e20), "query preserves number")
        case "cumulativeBound":
            for function in ["CUMIPMT", "CUMPRINC"] {
                checkValue("\(function)(0.01,1000000000000,1000,1,1000000000000,0)", .error(.num))
            }
        case "dateOverflow":
            checkValue("DATE(1000000000000000000,1,1)", .error(.num))
        case "dateMonthOverflow": checkValue("DATE(2026,9223372036854775807,1)", .error(.num))
        case "dateDayOverflow": checkValue("DATE(2026,1,9223372036854775807)", .error(.num))
        case "edateOverflow": checkValue("EDATE(DATE(2026,1,1),9223372036854775807)", .error(.num))
        case "eomonthOverflow": checkValue("EOMONTH(DATE(2026,1,1),9223372036854775807)", .error(.num))
        case "serialOverflow":
            checkEqual(DateSerial.civilDate(fromSerial: Int.max, system: .from1900), nil, "civil conversion is bounded")
        case "inputTimeOverflow":
            let text = "2026-11-15 23:59:9223372036854775807"
            checkEqual(CellInput.parse(text), .value(.text(text)), "invalid seconds stay text")
        case "csvTimeOverflow":
            let text = "2026-11-15 23:59:9223372036854775807"
            let file = try makeTemporaryDirectory().appendingPathComponent("invalid-seconds.csv")
            try Data((text + "\nx").utf8).write(to: file)
            let csv = try CSVReader.read(contentsOf: file)
            checkEqual(csv.workbook.sheets[0].cells[0, 0]?.value, .text(text), "CSV rejects invalid seconds")
        case "dosCalendar":
            let date = Date(timeIntervalSince1970: 1_794_739_200)
            var buddhist = Calendar(identifier: .buddhist)
            buddhist.timeZone = TimeZone(secondsFromGMT: 0)!
            var gregorian = Calendar(identifier: .gregorian)
            gregorian.timeZone = buddhist.timeZone
            checkEqual(DOSDateTime(date, calendar: buddhist), DOSDateTime(date, calendar: gregorian), "ZIP timestamp uses Gregorian year")
        case "fractionFormat":
            for (code, input, expected) in [("# ?/?", "1.5", "1 1/2"), ("# ??/??", "1.125", "1  1/8 "),
                                             ("# ?/?", "2", "2    "), ("# ?/?", "-1.5", "-1 1/2")] {
                checkEqual(ValueFormatter.format(num(input), code: code).text, expected, "\(input) as \(code)")
            }
            checkEqual(BuiltinFormats.code(for: 12), "# ?/?", "builtin 12")
            checkEqual(BuiltinFormats.code(for: 13), "# ??/??", "builtin 13")
        default: fail("unknown case \(name)")
        }
    }
}
