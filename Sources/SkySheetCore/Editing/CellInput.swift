import Foundation

/// 用户（以后还有 AI）在一个格子里输入的一段文字，按 Excel 的习惯变成什么（设计第 16 条）。
public enum CellInput: Equatable, Sendable {
    /// 空：清掉值和公式，样式留着。
    case clear
    case value(CellValue)
    /// 公式原文，不带 "="。
    case formula(String)
    /// 数字，外加一个建议的数字格式：格子原来是「常规」时才套上（输 5% 显示 5%，输 2025/12/1 显示日期）。
    case number(Decimal, format: SuggestedFormat?)

    public enum SuggestedFormat: Equatable, Sendable {
        case builtin(Int)
        case custom(String)
    }

    /// - "=" 开头是公式；"'" 开头强制当文字（'00123）；TRUE / FALSE 是逻辑值。
    /// - 12%、1,234.5、¥1,234.50、2025/12/1、2025-12-01 10:30 转成数字并建议对应的格式。
    /// - 别的都是文字。带前导 0 的数（00123）也是文字：账号、编号的 0 不能丢。
    /// 日期按工作簿的日期系统换成序列号（1904 系统的文件差 1462 天）。
    public static func parse(_ text: String, dateSystem: DateSystem = .from1900) -> CellInput {
        if text.isEmpty { return .clear }
        if text.hasPrefix("="), text.count > 1 { return .formula(String(text.dropFirst())) }
        if text.hasPrefix("'") { return .value(.text(String(text.dropFirst()))) }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch trimmed.uppercased() {
        case "TRUE": return .value(.bool(true))
        case "FALSE": return .value(.bool(false))
        default: break
        }
        if let (serial, hasTime) = dateValue(trimmed, dateSystem) {
            return .number(serial, format: .builtin(hasTime ? 22 : 14))
        }
        if keepsAsText(trimmed) { return .value(.text(text)) }
        if trimmed.hasSuffix("%"), let number = DecimalMath.parse(trimmed) {
            return .number(number, format: .builtin(trimmed.contains(".") ? 10 : 9))
        }
        if let number = DecimalMath.parse(trimmed) { return .number(number, format: nil) }
        if let (number, decimals, currency) = groupedNumber(trimmed) {
            let pattern = decimals ? "#,##0.00" : "#,##0"
            return .number(number, format: currency ? .custom("\"¥\"" + pattern) : .builtin(decimals ? 4 : 3))
        }
        return .value(.text(text))
    }

    /// 带前导 0 的整数、超过 15 位的数字串：Excel 会弄丢 0、截成 1.23E+17，我们留成文字。
    private static func keepsAsText(_ text: String) -> Bool {
        let unsigned = text.hasPrefix("-") || text.hasPrefix("+") ? String(text.dropFirst()) : text
        if unsigned.count > 1, unsigned.hasPrefix("0"), !unsigned.hasPrefix("0."), unsigned.allSatisfy(\.isNumber) {
            return true
        }
        return unsigned.filter(\.isNumber).count > 15 && unsigned.allSatisfy { $0.isNumber || $0 == "." }
    }

    /// 1,234、1,234.50、¥1,234.50、-¥12：千分位要规整（每组 3 位）。
    private static func groupedNumber(_ text: String) -> (Decimal, Bool, Bool)? {
        var body = text
        var negative = false
        if body.hasPrefix("-") { negative = true; body.removeFirst() }
        let currency = body.hasPrefix("¥") || body.hasPrefix("￥")
        if currency { body.removeFirst() }
        if body.hasPrefix("-") { negative = true; body.removeFirst() }
        let parts = body.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let groups = parts[0].split(separator: ",", omittingEmptySubsequences: false)
        guard groups.count > 1 || currency,
              let first = groups.first, (1...3).contains(first.count),
              groups.dropFirst().allSatisfy({ $0.count == 3 }),
              groups.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        let plain = groups.joined() + (parts.count > 1 ? "." + parts[1] : "")
        guard let number = DecimalMath.parse(plain) else { return nil }
        return (negative ? -number : number, parts.count > 1, currency)
    }

    /// 2025/12/1、2025-12-01，可以带 10:30 或 10:30:15。
    private static func dateValue(_ text: String, _ dateSystem: DateSystem) -> (Decimal, Bool)? {
        let parts = text.split(separator: " ", maxSplits: 1)
        let pieces = parts[0].split(whereSeparator: { $0 == "-" || $0 == "/" })
        guard pieces.count == 3, pieces[0].count == 4, let year = Int(pieces[0]), let month = Int(pieces[1]),
              let day = Int(pieces[2]), (1900...9999).contains(year), (1...12).contains(month),
              (1...DateSerial.daysInMonth(year: year, month: month)).contains(day) else { return nil }
        var serial = Decimal(DateSerial.serial(from: CivilDate(year: year, month: month, day: day), system: dateSystem))
        guard parts.count == 2 else { return (serial, false) }
        let clock = parts[1].split(separator: ":").map { Int($0) }
        guard (2...3).contains(clock.count), let hour = clock[0], let minute = clock[1],
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        let second = clock.count == 3 ? (clock[2] ?? 0) : 0
        serial += Decimal(hour * 3600 + minute * 60 + second) / 86_400
        return (serial, true)
    }
}
