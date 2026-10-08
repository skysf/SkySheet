import Foundation

/// Decimal 的几样常用操作。公式、数字格式都用这一份，不各写一遍。
public enum DecimalMath {
    /// 舍入到 `scale` 位小数（负数就是到十位、百位……）。
    /// `.plain` 遇 5 远离零（-2.5 → -3），和 Excel 的 ROUND 一样（2026-10-08 实测 NSDecimalRound 就是这样）。
    public static func round(_ value: Decimal, scale: Int, mode: NSDecimalNumber.RoundingMode = .plain) -> Decimal {
        var input = value
        var result = Decimal()
        NSDecimalRound(&result, &input, scale, mode)
        return result
    }

    /// 向零取整到 `scale` 位。对绝对值做，避开 `.down` 对负数到底朝哪边的歧义。
    public static func truncate(_ value: Decimal, scale: Int = 0) -> Decimal {
        value < 0 ? -round(-value, scale: scale, mode: .down) : round(value, scale: scale, mode: .down)
    }

    /// 远离零取整到 `scale` 位（Excel 的 ROUNDUP）。
    public static func roundAwayFromZero(_ value: Decimal, scale: Int = 0) -> Decimal {
        value < 0 ? -round(-value, scale: scale, mode: .up) : round(value, scale: scale, mode: .up)
    }

    /// 向负无穷取整（Excel 的 INT，日期序列号取日子也用它）。
    public static func floor(_ value: Decimal) -> Decimal {
        value < 0 ? -round(-value, scale: 0, mode: .up) : round(value, scale: 0, mode: .down)
    }

    public static func isInteger(_ value: Decimal) -> Bool {
        truncate(value) == value
    }

    /// 向零取整后的 Int；超出 Int 的范围返回 nil。
    public static func int(_ value: Decimal) -> Int? {
        let whole = truncate(value)
        guard whole >= Decimal(Int.min), whole <= Decimal(Int.max) else { return nil }
        return NSDecimalNumber(decimal: whole).intValue
    }

    public static func double(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
    }

    /// Double 转 Decimal：走最短的十进制写法（0.1 就是 0.1，不是 0.1000000000000000055…）。不是有限数返回 nil。
    public static func decimal(_ value: Double) -> Decimal? {
        guard value.isFinite else { return nil }
        return value == 0 ? 0 : Decimal(string: "\(value)")
    }

    /// 10 的 n 次方。
    public static func powerOfTen(_ exponent: Int) -> Decimal {
        Decimal(sign: .plus, exponent: exponent, significand: 1)
    }

    /// ⌊log10 |value|⌋，用 Decimal 自己的位数算，不经过 Double 的 log（避开 999.99999… 这类边界算错）。value 不能是 0。
    public static func exponent10(_ value: Decimal) -> Int {
        let digits = abs(value.significand).description.filter(\.isNumber).count
        return value.exponent + digits - 1
    }

    /// 保留 `digits` 位有效数字。
    public static func roundSignificant(_ value: Decimal, digits: Int) -> Decimal {
        guard value != 0 else { return 0 }
        return round(value, scale: digits - 1 - exponent10(value))
    }

    /// 普通写法（不用科学计数法），去掉小数末尾的 0。
    public static func plainString(_ value: Decimal) -> String {
        var text = value.description
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }

    /// 严格地把文字转成数字：整个字符串（去掉首尾空格）必须是一个数，比如 "12"、"-1.5"、"3e-2"、".5"、"12%"。
    /// 不能直接用 `Decimal(string:)`：它会只读到不认识的字符为止，"1,234" 会变成 1（2026-10-08 实测）。
    public static func parse(_ text: String) -> Decimal? {
        var scalars = Array(text.trimmingCharacters(in: .whitespaces).unicodeScalars)
        var percent = false
        if scalars.last == "%" {
            percent = true
            scalars.removeLast()
        }
        var index = 0
        func digits() -> Int {
            let start = index
            while index < scalars.count, ("0"..."9").contains(scalars[index]) { index += 1 }
            return index - start
        }
        if index < scalars.count, scalars[index] == "+" || scalars[index] == "-" { index += 1 }
        var mantissaDigits = digits()
        if index < scalars.count, scalars[index] == "." {
            index += 1
            mantissaDigits += digits()
        }
        guard mantissaDigits > 0 else { return nil }
        if index < scalars.count, scalars[index] == "e" || scalars[index] == "E" {
            index += 1
            if index < scalars.count, scalars[index] == "+" || scalars[index] == "-" { index += 1 }
            guard digits() > 0 else { return nil }
        }
        guard index == scalars.count,
              let value = Decimal(string: String(String.UnicodeScalarView(scalars)), locale: Locale(identifier: "en_US_POSIX"))
        else { return nil }
        return percent ? value / 100 : value
    }
}
