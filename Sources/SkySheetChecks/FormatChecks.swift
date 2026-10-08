import Foundation
import SkySheetCore

/// 设计第十二节第 2 条：数字格式。前几组的期望值来自样例 loan.xlsx 里腾讯文档的实际显示。
@MainActor
func formatChecks() {
    func shows(_ code: String, _ value: CellValue, _ expected: String, color: FormatColor? = nil,
               file: StaticString = #fileID, line: UInt = #line) {
        let formatted = ValueFormatter.format(value, code: code)
        checkEqual(formatted.text, expected, "format \(code) of \(value)", file: file, line: line)
        if let color {
            checkEqual(formatted.color, color, "color of \(code)", file: file, line: line)
        }
    }
    func number(_ text: String) -> CellValue { .number(Decimal(string: text)!) }

    group("format: cells of the loan fixture") {
        shows("0.0000%", number("0.0017864"), "0.1786%")                                  // G2
        shows("0.00%", number("0.0214368"), "2.14%")                                      // I2，内置编号 68
        shows("0.000%", number("0.0375644462330265"), "3.756%")                           // J5
        shows("\"¥\"#,##0.00_);[Red](\"¥\"#,##0.00)", number("3053.92"), "¥3,053.92 ")    // K2
        shows("\"¥\"#,##0.00_);[Red](\"¥\"#,##0.00)", number("-1234.5"), "(¥1,234.50)", color: .named("Red"))
        shows("#,##0.00_ ", number("82.5"), "82.50 ")                                     // E5
        shows("0.00", number("1358.33333333333"), "1358.33")                              // D3，内置编号 60
        shows("0.000", number("1214.01041666667"), "1214.010")                            // E3
        shows("yyyy\"年\"m\"月\"d\"日\"", number("45758"), "2025年4月11日")
        shows("yyyy/m/d", number("46303"), "2026/10/8")
    }

    group("format: builtin ids used by Tencent Docs") {
        let styles = StyleTable(cellFormats: [CellFormat(), CellFormat(numberFormatID: 68), CellFormat(numberFormatID: 60),
                                              CellFormat(numberFormatID: 14), CellFormat(numberFormatID: 31)])
        checkEqual(styles.formatCode(forStyle: 1), "0.00%", "68")
        checkEqual(styles.formatCode(forStyle: 2), "0.00", "60")
        checkEqual(styles.formatCode(forStyle: 3), "yyyy/m/d", "14 in a Chinese locale")
        checkEqual(styles.formatCode(forStyle: 4), "yyyy\"年\"m\"月\"d\"日\"", "31")
        checkEqual(styles.formatCode(forStyle: 99), "General", "unknown style index")
    }

    group("format: wan and yuan presets") {
        shows(FormatPreset.wan.code, number("489000"), "48.9万")
        shows(FormatPreset.wan.code, number("1234567"), "123.5万")
        shows(FormatPreset.wan.code, number("-489000"), "-48.9万")
        shows(FormatPreset.wanExact.code, number("489000"), "48.9000万")
        shows(FormatPreset.wanExact.code, number("1234567.89"), "123.4568万")
        shows(FormatPreset.cny.code, number("489000"), "¥489,000.00 ")
        shows(FormatPreset.cnyInteger.code, number("489000"), "¥489,000 ")
        shows(FormatPreset.percent.code, number("0.033"), "3.30%")
        shows("[$¥-804]#,##0.00", number("1234.5"), "¥1,234.50")
        shows("[>=10000]0!.0,\"万\";0", number("50000"), "5.0万")
        shows("[>=10000]0!.0,\"万\";0", number("500"), "500")
    }

    group("format: number placeholders") {
        shows("#,##0", number("1234567"), "1,234,567")
        shows("#,##0", number("0"), "0")
        shows("#,##0.00", number("-0.5"), "-0.50")
        shows("0.0,,\"M\"", number("12345678"), "12.3M")
        shows("#.##", number("5"), "5.")
        shows("0.##", number("5.1"), "5.1")
        shows("0.0#", number("5"), "5.0")
        shows("0.0?", number("5"), "5.0 ")
        shows("00000", number("42"), "00042")
        shows("0.00E+00", number("12345"), "1.23E+04")
        shows("0.00E+00", number("0.000123"), "1.23E-04")
        shows("0;-0;\"zero\"", number("0"), "zero")
        shows("0;-0;\"zero\"", number("-5"), "-5")
        shows("0;(0)", number("-5"), "(5)")
        shows("0", number("2.5"), "3")
        shows("0", number("-2.5"), "-3")
    }

    group("format: General") {
        shows("General", .number(Decimal(string: "0.1")! + Decimal(string: "0.2")!), "0.3")
        shows("General", .number(Decimal(1) / Decimal(3)), "0.333333333333333")
        shows("General", number("123456789012345"), "123456789012345")
        shows("General", number("1234567890123456"), "1.23456789012346E+15")
        shows("General", number("1e15"), "1E+15")
        shows("General", number("0.000000001"), "0.000000001")
        shows("General", number("1e-10"), "1E-10")
        shows("General", number("-489000"), "-489000")
        shows("\"¥\"General", number("12.5"), "¥12.5")
    }

    group("format: dates and times") {
        shows("yyyy/m/d h:mm", number("46303.5"), "2026/10/8 12:00")
        shows("h:mm AM/PM", number("0.75"), "6:00 PM")
        shows("h:mm:ss", number("0.5000115740740741"), "12:00:01")
        shows("[h]:mm:ss", number("1.5"), "36:00:00")
        shows("mm:ss.00", number("0.000011574"), "00:01.00")
        shows("ddd dddd", number("45758"), "Fri Friday")
        shows("aaaa", number("45758"), "星期五")
        shows("aaa", number("45758"), "五")
        shows("yy-mm-dd", number("45758"), "25-04-11")
        shows("d-mmm-yy", number("45758"), "11-Apr-25")
        shows("上午/下午h\"时\"mm\"分\"", number("0.25"), "上午6时00分")
        shows("yyyy/m/d", number("-1"), "########")
    }

    group("format: text and other values") {
        shows("@", .text("abc"), "abc")
        shows("0.00;0.00;0.00;\"note: \"@", .text("x"), "note: x")
        shows("0.00", .text("not a number"), "not a number")
        shows("0.00", .bool(true), "TRUE")
        shows("0.00", .error(.div0), "#DIV/0!")
        shows("0.00", .empty, "")
        shows("@", number("12.5"), "12.5")
    }

    group("dates: serial numbers") {
        checkEqual(DateSerial.serial(from: CivilDate(year: 2026, month: 10, day: 8), system: .from1900), 46303, "2026-10-08")
        checkEqual(DateSerial.civilDate(fromSerial: 45758, system: .from1900), CivilDate(year: 2025, month: 4, day: 11), "45758")
        checkEqual(DateSerial.civilDate(fromSerial: 1, system: .from1900), CivilDate(year: 1900, month: 1, day: 1), "serial 1")
        checkEqual(DateSerial.civilDate(fromSerial: 59, system: .from1900), CivilDate(year: 1900, month: 2, day: 28), "serial 59")
        checkEqual(DateSerial.civilDate(fromSerial: 60, system: .from1900), CivilDate(year: 1900, month: 2, day: 29), "the day that never was")
        checkEqual(DateSerial.civilDate(fromSerial: 61, system: .from1900), CivilDate(year: 1900, month: 3, day: 1), "serial 61")
        checkEqual(DateSerial.serial(from: CivilDate(year: 1900, month: 3, day: 1), system: .from1900), 61, "1900-03-01")
        checkEqual(DateSerial.civilDate(fromSerial: 0, system: .from1904), CivilDate(year: 1904, month: 1, day: 1), "1904 system")
        checkEqual(DateSerial.weekday(serial: 45758, system: .from1900), 6, "2025-04-11 is a Friday")
        checkEqual(DateSerial.weekday(serial: 1, system: .from1900), 1, "Excel calls 1900-01-01 a Sunday")
    }

    group("numbers: strict parsing") {
        checkEqual(DecimalMath.parse("12"), Decimal(12), "12")
        checkEqual(DecimalMath.parse(" -1.5 "), Decimal(string: "-1.5"), "-1.5")
        checkEqual(DecimalMath.parse("3e-2"), Decimal(string: "0.03"), "3e-2")
        checkEqual(DecimalMath.parse(".5"), Decimal(string: "0.5"), ".5")
        checkEqual(DecimalMath.parse("12%"), Decimal(string: "0.12"), "12%")
        checkEqual(DecimalMath.parse("1,234"), nil, "comma is not part of a number")
        checkEqual(DecimalMath.parse("12abc"), nil, "trailing text")
        checkEqual(DecimalMath.parse(""), nil, "empty")
        checkEqual(DecimalMath.parse("e5"), nil, "exponent without mantissa")
    }
}
