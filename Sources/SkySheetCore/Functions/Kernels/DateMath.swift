import Foundation

/// 日期函数共用的算法（设计 5.2 节 DateMath）。都在序列号上算，换算交给 DateSerial。
enum DateMath {
    /// DATE(year, month, day) 的规则：0–1899 年加 1900；月、日可以超出范围，自动进位
    /// （第 13 个月是下一年 1 月，第 0 天是上个月最后一天）。在序列号上加天数，所以 DATE(1900,2,29) 也和 Excel 一样是 60。
    static func serial(year: Int, month: Int, day: Int, system: DateSystem) throws(CellError) -> Int {
        let fullYear = (0...1899).contains(year) ? year + 1900 : year
        let months = fullYear * 12 + (month - 1)
        let (normalizedYear, normalizedMonth) = splitMonths(months)
        guard (1900...9999).contains(normalizedYear) else { throw CellError.num }
        let first = DateSerial.serial(from: CivilDate(year: normalizedYear, month: normalizedMonth, day: 1), system: system)
        let result = first + day - 1
        guard result >= 0 else { throw CellError.num }
        return result
    }

    static func civil(_ serial: Int, system: DateSystem) throws(CellError) -> CivilDate {
        guard let date = DateSerial.civilDate(fromSerial: serial, system: system) else { throw CellError.num }
        return date
    }

    /// EDATE：加 n 个月，日子超过那个月的天数就取月底（1 月 31 日加一个月是 2 月 28 / 29 日）。
    static func addMonths(_ serial: Int, months: Int, system: DateSystem) throws(CellError) -> Int {
        let date = try civil(serial, system: system)
        let (year, month) = splitMonths(date.year * 12 + date.month - 1 + months)
        guard (1900...9999).contains(year) else { throw CellError.num }
        let day = min(date.day, DateSerial.daysInMonth(year: year, month: month))
        return DateSerial.serial(from: CivilDate(year: year, month: month, day: day), system: system)
    }

    /// EOMONTH：加 n 个月之后那个月的最后一天。
    static func endOfMonth(_ serial: Int, months: Int, system: DateSystem) throws(CellError) -> Int {
        let date = try civil(serial, system: system)
        let (year, month) = splitMonths(date.year * 12 + date.month - 1 + months)
        guard (1900...9999).contains(year) else { throw CellError.num }
        return DateSerial.serial(from: CivilDate(year: year, month: month,
                                                 day: DateSerial.daysInMonth(year: year, month: month)), system: system)
    }

    /// DATEDIF：两个日期之间满几年（Y）、满几个月（M）、几天（D），以及忽略年月的 MD、YM、YD。
    static func difference(from start: Int, to end: Int, unit: String, system: DateSystem) throws(CellError) -> Int {
        guard start <= end else { throw CellError.num }
        let first = try civil(start, system: system)
        let last = try civil(end, system: system)
        let monthsBetween = (last.year - first.year) * 12 + last.month - first.month - (last.day < first.day ? 1 : 0)
        switch unit.uppercased() {
        case "Y": return monthsBetween / 12
        case "M": return monthsBetween
        case "D": return end - start
        case "YM": return monthsBetween % 12
        case "MD":
            if last.day >= first.day { return last.day - first.day }
            let (year, month) = splitMonths(last.year * 12 + last.month - 2)
            return DateSerial.daysInMonth(year: year, month: month) - first.day + last.day
        case "YD":
            var anniversaryYear = last.year
            if (last.month, last.day) < (first.month, first.day) { anniversaryYear -= 1 }
            let day = min(first.day, DateSerial.daysInMonth(year: anniversaryYear, month: first.month))
            let anniversary = DateSerial.serial(from: CivilDate(year: anniversaryYear, month: first.month, day: day),
                                                system: system)
            return end - anniversary
        default:
            throw CellError.num
        }
    }

    /// 从 0 年 1 月起数的月数 → (年, 月)，负数也对。
    private static func splitMonths(_ months: Int) -> (year: Int, month: Int) {
        let year = months >= 0 ? months / 12 : (months - 11) / 12
        return (year, months - year * 12 + 1)
    }
}
