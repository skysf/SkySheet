import Foundation

/// 公历日期（年、月、日）。
public struct CivilDate: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public static func < (lhs: CivilDate, rhs: CivilDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// 本机时区的今天。
    public static func today(calendar: Calendar = .current) -> CivilDate {
        let parts = calendar.dateComponents([.year, .month, .day], from: Date())
        return CivilDate(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }
}

/// 日期序列号和公历日期互换。数字格式显示日期、日期函数都用这一份（设计 5.2 节 DateMath）。
///
/// 1900 系统：1 = 1900-01-01。Excel 把 1900 年当闰年（照抄 Lotus 1-2-3 的 bug），60 是并不存在的 1900-02-29。
/// 我们照抄，否则 1900 年 3 月以后的每个日期都和 Excel、腾讯文档差一天。
public enum DateSerial {
    public static func civilDate(fromSerial serial: Int, system: DateSystem) -> CivilDate? {
        guard serial >= 0 else { return nil }
        switch system {
        case .from1904:
            return civil(fromDays: epoch1904 + serial)
        case .from1900:
            if serial == 0 { return CivilDate(year: 1900, month: 1, day: 0) }   // Excel 显示 1900-01-00
            if serial == 60 { return CivilDate(year: 1900, month: 2, day: 29) } // 不存在的那一天
            return civil(fromDays: epoch1900 + (serial < 60 ? serial : serial - 1))
        }
    }

    /// 序列号写成 ISO 的样子：2025-12-01；带时刻的 2025-12-01 10:30:00（四舍五入到秒）；不到一天的只有时刻。
    /// 存 csv、导出给 Python、SQL 查询里的日期都用它。负数和不存在的日子返回 nil。
    public static func isoText(_ serial: Decimal, system: DateSystem) -> String? {
        guard serial >= 0 else { return nil }
        var seconds = Int(DecimalMath.double(serial * 86_400).rounded())
        let days = seconds / 86_400
        seconds %= 86_400
        let time = String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        guard days > 0 else { return time }
        guard let date = civilDate(fromSerial: days, system: system), date.day > 0 else { return nil }
        let day = String(format: "%04d-%02d-%02d", date.year, date.month, date.day)
        return seconds > 0 ? day + " " + time : day
    }

    public static func serial(from date: CivilDate, system: DateSystem) -> Int {
        let days = days(fromCivil: date)
        switch system {
        case .from1904:
            return days - epoch1904
        case .from1900:
            return days >= march1st1900 ? days - epoch1900 + 1 : days - epoch1900
        }
    }

    /// 1 = 星期日 … 7 = 星期六（Excel 的 WEEKDAY 默认就是这样）。
    /// 1900 系统里 1900 年 3 月以前的星期和 Excel 一样「错」：都按那个不存在的 2 月 29 日算。
    public static func weekday(serial: Int, system: DateSystem) -> Int {
        switch system {
        case .from1900:
            return (serial + 6) % 7 + 1
        case .from1904:
            let days = epoch1904 + serial
            return ((days + 4) % 7 + 7) % 7 + 1   // 1970-01-01 是星期四
        }
    }

    public static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: isLeapYear(year) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    public static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    // MARK: - 公历日期 ↔ 1970-01-01 起的天数
    //
    // Howard Hinnant 的算法：纯整数运算，不经过 Calendar，快，和时区无关。

    static let epoch1900 = days(fromCivil: CivilDate(year: 1899, month: 12, day: 31))
    static let epoch1904 = days(fromCivil: CivilDate(year: 1904, month: 1, day: 1))
    static let march1st1900 = days(fromCivil: CivilDate(year: 1900, month: 3, day: 1))

    static func days(fromCivil date: CivilDate) -> Int {
        let y = date.month <= 2 ? date.year - 1 : date.year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let shiftedMonth = date.month > 2 ? date.month - 3 : date.month + 9
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + date.day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    static func civil(fromDays days: Int) -> CivilDate {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return CivilDate(year: year, month: month, day: day)
    }
}
