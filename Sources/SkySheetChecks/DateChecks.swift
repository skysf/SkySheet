import Foundation
import SkySheetCore
import SkySheetFiles


@MainActor
func dateRegressionChecks() {
    gregorianTodayChecks()
    boundedCheck("dateOverflow")
    boundedCheck("dateMonthOverflow")
    boundedCheck("dateDayOverflow")
    boundedCheck("edateOverflow")
    boundedCheck("eomonthOverflow")
    boundedCheck("serialOverflow")
    boundedCheck("boundaryDates")
}

@MainActor
func gregorianTodayChecks() {
    group("date: gregorianToday") {
        let instant = Date(timeIntervalSince1970: 1_794_739_200)
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(secondsFromGMT: 28_800)!
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = buddhist.timeZone
        let day = CivilDate.today(at: instant, calendar: gregorian)
        checkEqual(CivilDate.today(at: instant, calendar: buddhist), day, "calendar setting cannot change TODAY")
        var workbook = Workbook(sheets: [makeSheet("S", id: 1, ["A1": "=TODAY()", "A2": "=YEAR(TODAY())"])])
        Recalculator.recalculate(&workbook, options: RecalcOptions(today: CivilDate.today(at: instant, calendar: buddhist)))
        checkEqual(workbook.sheets[0].cells[0, 0]?.value, .number(Decimal(DateSerial.serial(from: day, system: .from1900))), "TODAY is Gregorian")
        checkEqual(workbook.sheets[0].cells[1, 0]?.value, .number(Decimal(day.year)), "YEAR(TODAY) is Gregorian")
    }
}

@MainActor
func dateOverflowChecks() {
    group("date: dateOverflow") {
        checkValue("DATE(1000000000000000000,1,1)", .error(.num))
    }
}

@MainActor
func dateMonthOverflowChecks() {
    group("date: dateMonthOverflow") {
        checkValue("DATE(2026,9223372036854775807,1)", .error(.num))
    }
}

@MainActor
func dateDayOverflowChecks() {
    group("date: dateDayOverflow") {
        checkValue("DATE(2026,1,9223372036854775807)", .error(.num))
    }
}

@MainActor
func edateOverflowChecks() {
    group("date: edateOverflow") {
        checkValue("EDATE(DATE(2026,1,1),9223372036854775807)", .error(.num))
    }
}

@MainActor
func eomonthOverflowChecks() {
    group("date: eomonthOverflow") {
        checkValue("EOMONTH(DATE(2026,1,1),9223372036854775807)", .error(.num))
    }
}

@MainActor
func serialOverflowChecks() {
    group("date: serialOverflow") {
        checkEqual(DateSerial.civilDate(fromSerial: Int.max, system: .from1900), nil, "civil conversion is bounded")
    }
}

@MainActor
func boundaryDatesChecks() {
    group("date: boundaryDates") {
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

    }
}
