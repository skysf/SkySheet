import Foundation

/// 输入和 CSV 共用合法性检查，避免同一个日期因入口不同变成不同的值。
public enum DateInput {
    /// 2025/12/1、2025-12-01，可以带 10:30 或 10:30:15。
    public static func parse(_ text: String, system dateSystem: DateSystem = .from1900) -> (Decimal, Bool)? {
        let parts = text.split(separator: " ", maxSplits: 1)
        guard let datePart = parts.first else { return nil }
        let pieces = datePart.split(whereSeparator: { $0 == "-" || $0 == "/" })
        guard pieces.count == 3, pieces[0].count == 4, let year = Int(pieces[0]), let month = Int(pieces[1]),
              let day = Int(pieces[2]), (1900...9999).contains(year), (1...12).contains(month),
              (1...DateSerial.daysInMonth(year: year, month: month)).contains(day) else { return nil }
        var serial = Decimal(DateSerial.serial(from: CivilDate(year: year, month: month, day: day), system: dateSystem))
        guard parts.count == 2 else { return (serial, false) }
        let clock = parts[1].split(separator: ":").map { Int($0) }
        guard (2...3).contains(clock.count), let hour = clock[0], let minute = clock[1],
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        guard let second = clock.count == 3 ? clock[2] : 0, (0...59).contains(second) else { return nil }
        serial += Decimal(hour * 3600 + minute * 60 + second) / 86_400
        return (serial, true)
    }
}
