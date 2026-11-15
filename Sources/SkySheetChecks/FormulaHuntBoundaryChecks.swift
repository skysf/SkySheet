import Foundation
import SkySheetCore
import SkySheetFiles

/// 修复入口的相邻边界：既挡坏输入，也保留正常区域、日期进位、现金流和格式的行为。
@MainActor
func formulaHuntBoundaryChecks(_ name: String) {
    switch name {
    case "boundaryCriteria": group("formula hunt boundaries: sparse criteria") {
        let cells = ["A1": "1", "A2": "=\"\"", "B1": "10", "B2": "20", "B3": "30"]
        checkValue("COUNTIF(A1:A4,\"\")", cells, num("3"))
        checkValue("COUNTIF(A1:A4,\"<>\")", cells, num("1"))
        checkValue("SUMIF(A1:A4,\"\",B1:B4)", cells, num("50"))
        checkValue("SUMIFS(B1:B4,A1:A4,\"\")", cells, num("50"))
        checkValue("AVERAGEIFS(B1:B4,A1:A4,\"\")", cells, num("25"))
        checkValue("SUMIF(A1:A3,\"\",B1)", cells, num("50"))
        checkValue("AVERAGEIF(A1:A3,\"\",B1)", cells, num("25"))
        checkValue("SUMIFS(B1:B4,A1:A3,\"\")", cells, .error(.value))
        checkValue("AVERAGEIFS(B1:B4,A1:A3,\"\")", cells, .error(.value))
        checkValue("COUNTIFS(A1:A3,\"\",B1:B2,\">0\")", cells, .error(.value))
        checkValue("COUNTIFS(99,99,A1:A2,\">0\")", cells, .error(.value))
        checkValue("SUMIF(A1:A3,\"\",99)", cells, .error(.value))
        checkValue("COUNTIF(3:3,\"\")", ["A3": "1"], num("16383"))
        checkValue("COUNTIFS(A1:B2,\"\",C1:D2,\"\")", ["A1": "x", "D2": "y"], num("2"))
        checkEqual(evaluate("COUNTIFS(A1:A2,\"\",Other!B1:B2,\"\")", ["A1": "x"], otherSheets: ["Other": [:]]), num("1"), "cross-sheet blanks")
        checkValue("SUMIF(A1:A3,\"\",B1:B3)", ["A1": "1", "B2": "=#N/A"], .error(.na))
        checkValue("SUMIF(A1:A3,\"\",B1:B3)", ["A1": "1", "B1": "=#N/A", "B2": "3"], num("3"))
    }
    case "boundaryLookup": group("formula hunt boundaries: lookup and text") {
        let cells = ["A1": "1", "A2": "2", "B1": "7", "B2": "8"]
        checkValue("XLOOKUP(2,A1:A2,B1:B2)", cells, num("8"))
        checkValue("XLOOKUP(2,A1:A2,B1)", cells, .error(.value))
        checkValue("XLOOKUP(1,A1:B1,A2:A3)", cells, .error(.value))
        checkValue("XLOOKUP(99,A1:A2,B1:B2,\"missing\")", cells, .text("missing"))
        for formula in ["LEFT(\"😀\",1)", "RIGHT(\"😀\",1)", "MID(\"😀X\",2,1)"] {
            checkValue(formula, .text("\u{FFFD}"))
        }
        checkValue("MID(\"😀X\",3,1)", .text("X"))
        checkValue("LEFT(\"😀X\",2)", .text("😀"))
        checkValue("LEFT(\"😀X\",9223372036854775807)", .text("😀X"))
        checkValue("RIGHT(\"😀X\",9223372036854775807)", .text("😀X"))
        checkValue("MID(\"abc\",9223372036854775807,9223372036854775807)", .text(""))
        checkValue("LEFT(\"abc\",-1)", .error(.value))
    }
    case "boundaryTotals": group("formula hunt boundaries: real totals") {
        let base = ["A1": "Name", "B1": "Amount", "A2": "Alice", "B2": "1", "A3": "Bob", "B3": "2"]
        for formula in ["=SUM(B2:B3)", "=SUBTOTAL(9,B2:B3)", "=SUBTOTAL(109,B2:B3)"] {
            var cells = base
            cells["B4"] = formula
            checkEqual(TableBlocks.find(in: makeSheet("S", id: 1, cells))[0].totalsRow, 3, "vertical sum is total")
        }
        for label in ["合计", "总计", "Total", " Grand Total "] {
            var cells = base
            cells["A4"] = label
            cells["B4"] = "3"
            checkEqual(TableBlocks.find(in: makeSheet("S", id: 1, cells))[0].totalsRow, 3, "explicit label is total")
        }
        for formula in ["=SUM(B2,3)", "=SUM(B3:B3)", "=SUM(A4:B4)", "=SUBTOTAL(1,B2:B3)", "=SUM(Other!B2:B3)"] {
            var cells = base
            cells["C4"] = formula
            checkEqual(TableBlocks.find(in: makeSheet("S", id: 1, cells))[0].totalsRow, nil, "uncertain total remains data")
        }
    }
    case "boundaryDates": group("formula hunt boundaries: dates and formats") {
        for system in [DateSystem.from1900, .from1904] {
            let last = DateSerial.maximumSerial(system: system)
            checkEqual(DateSerial.civilDate(fromSerial: last, system: system), CivilDate(year: 9999, month: 12, day: 31), "last valid day")
            checkEqual(DateSerial.isoText(Decimal(last), system: system), "9999-12-31", "last ISO day")
            for number in [Decimal(last + 1), Decimal(Int.max), Decimal(string: "1e100")!, Decimal(-1)] {
                checkEqual(DateSerial.isoText(number, system: system), nil, "invalid ISO date")
                checkEqual(ValueFormatter.format(.number(number), code: "[s].000", dateSystem: system).text, "########", "elapsed format is bounded")
            }
        }
        checkValue("DATE(2026,13,0)", .number(46387))
        for formula in ["DATE(2026,-9223372036854775808,1)", "DATE(2026,1,-9223372036854775808)",
                        "DATE(9999,12,32)", "YEAR(9223372036854775807)"] {
            checkValue(formula, .error(.num))
        }
        for text in ["¥", "-", "+", "2026-11-15 23:59:60", "2026-11-15 23:59:abc"] {
            checkEqual(CellInput.parse(text), .value(.text(text)), "invalid input stays text")
        }
        checkEqual(ValueFormatter.format(num("0"), code: "ss." + String(repeating: "0", count: 14)).text,
                   "00." + String(repeating: "0", count: 14), "largest safe second precision")
        checkEqual(ValueFormatter.format(num("0.5"), code: "0." + String(repeating: "0", count: 100)).text.count, 102, "fixed format has no integer power trap")
        for (number, code, expected) in [("1.33333333333333", "# ?/?", "1 1/3"), ("0.5", "# ?/?", " 1/2"),
                                         ("-2", "# ?/?", "-2    "), ("2", "# ??/??", "2      "),
                                         ("-1.125", "# ??/??", "-1  1/8 "), ("1.99", "# ?/?", "2    "),
                                         ("1.234", "# ??/??", "1 11/47"), ("1.5", "# ?/?;(# ?/?)", "1 1/2")] {
            checkEqual(ValueFormatter.format(num(number), code: code).text, expected, "fraction \(number) \(code)")
        }
        checkValue("TEXT(1.5,\"# ?/?\")", .text("1 1/2"))
        for digits in [5, 100] {
            checkEqual(ValueFormatter.format(num("1.5"), code: "# ?/" + String(repeating: "?", count: digits)).text,
                       "########", "unsupported denominator precision is bounded")
        }
        checkEqual(ValueFormatter.format(num("1"), code: "0\"/\"0").text, "0/1", "quoted slash is literal")
    }
    case "boundaryCumulative": group("formula hunt boundaries: cumulative cash flows") {
        for type in 0...1 {
            for (first, last) in [(1, 1), (1, 12), (5, 12)] {
                var interest = 0.0
                var principal = 0.0
                for period in first...last {
                    let values = "5%/12,\(period),12,1000,0,\(type)"
                    interest += DecimalMath.double(evaluate("IPMT(\(values))").number!)
                    principal += DecimalMath.double(evaluate("PPMT(\(values))").number!)
                }
                let arguments = "5%/12,12,1000,\(first),\(last),\(type)"
                checkNumber(evaluate("CUMIPMT(\(arguments))"), interest, tolerance: 1e-11, "cumulative interest matches periods")
                checkNumber(evaluate("CUMPRINC(\(arguments))"), principal, tolerance: 1e-11, "cumulative principal matches periods")
            }
        }
        checkValue("CUMPRINC(0.01,1000000000000,1000,1,1000000000000,0)", .error(.num))
        let bounded = evaluate("CUMIPMT(0.0000000000001,1000000000000,1000,1,1000000000000,0)")
        check(bounded.number.map { $0 < 0 && $0 > -1000 } == true, "finite payment with huge period count is bounded")
    }
    default: fail("unknown boundary \(name)")
    }
}
