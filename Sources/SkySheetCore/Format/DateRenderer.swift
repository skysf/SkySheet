import Foundation

/// 按日期时间段渲染：整数部分是日子（序列号），小数部分是一天里的时刻。
enum DateRenderer {
    /// 负数和超出范围的日期，Excel 显示一串 #。
    static let invalid = "########"

    static func render(_ value: Decimal, section: FormatSection, system: DateSystem) -> String {
        guard value >= 0 else { return invalid }
        let subsecondDigits = section.tokens.lazy.compactMap { token -> Int? in
            if case .date(.subsecond(let digits)) = token { return digits }
            return nil
        }.first ?? 0
        let unitsPerSecond = Int(pow(10, Double(subsecondDigits)))
        let unitsPerDay = 86_400 * unitsPerSecond

        guard var day = DecimalMath.int(DecimalMath.floor(value)) else { return invalid }
        let fraction = value - Decimal(day)
        var units = DecimalMath.int(DecimalMath.round(fraction * Decimal(unitsPerDay), scale: 0)) ?? 0
        if units >= unitsPerDay {   // 23:59:59.9 进位到第二天
            day += 1
            units -= unitsPerDay
        }
        guard let date = DateSerial.civilDate(fromSerial: day, system: system), date.year <= 9999 else { return invalid }

        let seconds = units / unitsPerSecond
        let clock = Clock(day: day, hour: seconds / 3600, minute: seconds % 3600 / 60, second: seconds % 60,
                          subsecond: units % unitsPerSecond)
        let twelveHour = section.tokens.contains { token in
            if case .date(.ampm) = token { return true }
            return false
        }
        var result = ""
        for token in section.tokens {
            switch token {
            case .literal(let text): result += text
            case .date(let part): result += text(part, date: date, clock: clock, twelveHour: twelveHour, system: system)
            case .decimalPoint: result += "."
            default: break
            }
        }
        return result
    }

    private struct Clock {
        let day: Int
        let hour: Int
        let minute: Int
        let second: Int
        let subsecond: Int
    }

    private static func text(_ part: DatePart, date: CivilDate, clock: Clock, twelveHour: Bool,
                             system: DateSystem) -> String {
        switch part {
        case .year(let digits):
            return digits == 2 ? pad(date.year % 100, 2) : String(date.year)
        case .month(let style):
            let name = monthNames[max(0, min(11, date.month - 1))]
            switch style {
            case 1: return String(date.month)
            case 2: return pad(date.month, 2)
            case 3: return String(name.prefix(3))
            case 4: return name
            default: return String(name.prefix(1))
            }
        case .day(let style):
            let weekday = DateSerial.weekday(serial: clock.day, system: system) - 1
            switch style {
            case 1: return String(date.day)
            case 2: return pad(date.day, 2)
            case 3: return String(weekdayNames[weekday].prefix(3))
            default: return weekdayNames[weekday]
            }
        case .chineseWeekday(let style):
            let weekday = DateSerial.weekday(serial: clock.day, system: system) - 1
            let short = String(Array("日一二三四五六")[weekday])
            return style == 3 ? short : "星期" + short
        case .hour(let digits):
            let hour = twelveHour ? (clock.hour % 12 == 0 ? 12 : clock.hour % 12) : clock.hour
            return digits == 2 ? pad(hour, 2) : String(hour)
        case .minute(let digits):
            return digits == 2 ? pad(clock.minute, 2) : String(clock.minute)
        case .second(let digits):
            return digits == 2 ? pad(clock.second, 2) : String(clock.second)
        case .subsecond(let digits):
            return "." + pad(clock.subsecond, digits)
        case .elapsedHours(let digits):
            return pad(clock.day * 24 + clock.hour, digits)
        case .elapsedMinutes(let digits):
            return pad((clock.day * 24 + clock.hour) * 60 + clock.minute, digits)
        case .elapsedSeconds(let digits):
            return pad(((clock.day * 24 + clock.hour) * 60 + clock.minute) * 60 + clock.second, digits)
        case .ampm(let style):
            let morning = clock.hour < 12
            switch style {
            case .upper: return morning ? "AM" : "PM"
            case .letter: return morning ? "A" : "P"
            case .chinese: return morning ? "上午" : "下午"
            }
        }
    }

    private static func pad(_ number: Int, _ width: Int) -> String {
        let text = String(number)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }

    private static let monthNames = ["January", "February", "March", "April", "May", "June", "July",
                                     "August", "September", "October", "November", "December"]
    private static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
}
