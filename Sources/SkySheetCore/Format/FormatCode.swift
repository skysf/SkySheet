import Foundation

/// 解析好的数字格式代码（Excel 的规则，设计第六节）。最多四段：正数;负数;零;文字。
struct FormatCode: Sendable {
    let sections: [FormatSection]

    /// 文字用哪一段：第 4 段；只有一段并且是文字格式（"@"）时就是它。都没有就原样显示文字。
    var textSection: FormatSection? {
        if sections.count >= 4 { return sections[3] }
        if sections.count == 1, sections[0].kind == .text { return sections[0] }
        return nil
    }

    /// 数字用哪一段，以及要不要在前面加负号。
    /// 没有条件时：一段的负数自己加 "-"；两段以上负数用第 2 段、按绝对值显示（负号要的话写在格式里）。
    func section(for value: Decimal) -> (section: FormatSection, showMinus: Bool) {
        let numeric = Array(sections.prefix(3))
        if numeric.contains(where: { $0.condition != nil }) {
            if let matched = numeric.first(where: { $0.condition?.matches(value) == true }) {
                return (matched, value < 0)
            }
            return (numeric.first(where: { $0.condition == nil }) ?? numeric[0], value < 0)
        }
        switch numeric.count {
        case 1:
            return (numeric[0], value < 0)
        case 2:
            return (value < 0 ? numeric[1] : numeric[0], false)
        default:
            if value > 0 { return (numeric[0], false) }
            return (value < 0 ? numeric[1] : numeric[2], false)
        }
    }
}

struct FormatSection: Sendable {
    enum Kind: Sendable, Equatable {
        case general, number, date, text
        /// 只有文字、没有任何占位符（比如零值段写成 "-"）。
        case literal
    }

    var tokens: [FormatToken] = []
    var kind: Kind = .literal
    var color: FormatColor?
    var condition: FormatCondition?
    /// 有几个 %：每个乘一次 100。
    var percentCount = 0
    /// 数字后面跟着几个逗号：每个除以一次 1000（`0!.0,"万"` 就是靠它）。
    var thousandsScale = 0
    /// 整数部分要不要千分位。
    var groupsThousands = false
}

enum FormatToken: Sendable, Equatable {
    case literal(String)
    case digit(DigitPlaceholder)
    case decimalPoint
    /// 千分位或者缩放，解析时归好类，渲染时不输出。
    case comma
    case percent
    case exponent(showsPlus: Bool)
    /// "@"：文字本身。
    case text
    case general
    case date(DatePart)

    var isDigit: Bool {
        if case .digit = self { return true }
        return false
    }

    var isDate: Bool {
        if case .date = self { return true }
        return false
    }

    var isExponent: Bool {
        if case .exponent = self { return true }
        return false
    }
}

enum DigitPlaceholder: Sendable, Equatable {
    /// 0：没有数字也显示 0。
    case zero
    /// #：没有数字就什么都不显示。
    case hash
    /// ?：没有数字显示一个空格（为了对齐）。
    case question
}

enum DatePart: Sendable, Equatable {
    /// 2 或 4 位。
    case year(Int)
    /// 1 m，2 mm，3 mmm（Jan），4 mmmm（January），5 mmmmm（J）。
    case month(Int)
    /// 1 d，2 dd，3 ddd（Mon），4 dddd（Monday）。
    case day(Int)
    /// 中文环境的星期：3 aaa（一），4 aaaa（星期一）。
    case chineseWeekday(Int)
    case hour(Int)
    case minute(Int)
    case second(Int)
    /// 秒后面的小数：ss.0 / ss.00 / ss.000。
    case subsecond(Int)
    case elapsedHours(Int)
    case elapsedMinutes(Int)
    case elapsedSeconds(Int)
    case ampm(AMPMStyle)
}

enum AMPMStyle: Sendable, Equatable {
    case upper      // AM/PM
    case letter     // A/P
    case chinese    // 上午/下午
}

/// 格式里的颜色（`[Red]`、`[Color10]`）。M2 画表格时用。
public enum FormatColor: Hashable, Sendable {
    case named(String)
    case indexed(Int)
}

/// 格式里的条件（`[>=10000]`）。
struct FormatCondition: Sendable {
    enum Operator: Sendable {
        case less, lessOrEqual, greater, greaterOrEqual, equal, notEqual
    }

    let op: Operator
    let value: Decimal

    init?(_ text: String) {
        let pairs: [(String, Operator)] = [("<=", .lessOrEqual), (">=", .greaterOrEqual), ("<>", .notEqual),
                                           ("<", .less), (">", .greater), ("=", .equal)]
        guard let (symbol, op) = pairs.first(where: { text.hasPrefix($0.0) }),
              let value = DecimalMath.parse(String(text.dropFirst(symbol.count)))
        else { return nil }
        self.op = op
        self.value = value
    }

    func matches(_ number: Decimal) -> Bool {
        switch op {
        case .less: number < value
        case .lessOrEqual: number <= value
        case .greater: number > value
        case .greaterOrEqual: number >= value
        case .equal: number == value
        case .notEqual: number != value
        }
    }
}
