import Foundation
import Synchronization

/// 显示出来的样子：文字，加上格式里指定的颜色（`[Red]`），没有就是 nil。
public struct FormattedValue: Hashable, Sendable {
    public var text: String
    public var color: FormatColor?

    public init(text: String, color: FormatColor? = nil) {
        self.text = text
        self.color = color
    }
}

/// 按数字格式代码显示一个值。表格显示、TEXT() 函数、AI 读到的显示文字都走这里（设计第六节）。
public enum ValueFormatter {
    public static func format(_ value: CellValue, code: String, dateSystem: DateSystem = .from1900) -> FormattedValue {
        let format = FormatCodeCache.shared.parsed(code)
        switch value {
        case .empty:
            return FormattedValue(text: "")
        case .bool(let flag):
            return FormattedValue(text: flag ? "TRUE" : "FALSE")
        case .error(let error):
            return FormattedValue(text: error.code)
        case .text(let text):
            guard let section = format.textSection else { return FormattedValue(text: text) }
            return FormattedValue(text: renderText(text, section), color: section.color)
        case .number(let number):
            let (section, showMinus) = format.section(for: number)
            let text: String = switch section.kind {
            case .date: DateRenderer.render(number, section: section, system: dateSystem)
            case .number, .general: NumberRenderer.render(number, section: section, showMinus: showMinus)
            case .text: (showMinus ? "-" : "") + GeneralFormat.render(abs(number))   // 文字格式里的数字按「常规」显示
            case .literal: renderText("", section)
            }
            return FormattedValue(text: text, color: section.color)
        }
    }

    /// 数字的「常规」写法（默认 15 位有效数字）。公式里把数字接成文字时用它；表格里列太窄时显示层用更少的位数。
    public static func general(_ number: Decimal, significantDigits: Int = 15) -> String {
        GeneralFormat.render(number, significantDigits: significantDigits)
    }

    /// 格式的粗分类（只看第一段）；有具体数值的日期系统换算应使用 isCalendarDateFormat。
    public static func isDateFormat(_ code: String) -> Bool {
        FormatCodeCache.shared.parsed(code).sections.first?.kind == .date
    }

    /// 日期系统只影响日历日期和日期时间；纯时间、累计时长都没有需要平移的纪元。
    /// 和渲染共用分段选择，条件、负数和零不能借用第一段的类型。
    public static func isCalendarDateFormat(_ code: String, for number: Decimal) -> Bool {
        FormatCodeCache.shared.parsed(code).section(for: number).section.isCalendarDate
    }

    /// 源值当时生效的那一段是日历日期时，返回只有这一段、去掉条件的格式原文；否则 nil。
    /// 跨日期系统粘贴到常规格用它：整份格式跟过去，换算后的数会按条件和正负零重新选段，日期就变回数字。
    public static func calendarDateSection(_ code: String, for number: Decimal) -> String? {
        let format = FormatCodeCache.shared.parsed(code)
        let index = format.sectionIndex(for: number).index
        guard format.sections[index].isCalendarDate else { return nil }
        // parse 就是按 splitSections 的结果逐段解析的，下标一一对应。
        return FormatParser.removingCondition(FormatParser.splitSections(code)[index])
    }

    /// 这个格式（第一段）有几个 %：每个乘一次 100。存 csv 时百分比写成「5%」，读回来还是同一个数。
    public static func percentCount(_ code: String) -> Int {
        FormatCodeCache.shared.parsed(code).sections.first?.percentCount ?? 0
    }

    private static func renderText(_ text: String, _ section: FormatSection) -> String {
        section.tokens.reduce(into: "") { result, token in
            switch token {
            case .literal(let literal): result += literal
            case .text: result += text
            default: break
            }
        }
    }
}

/// 解析过的格式代码缓存：一张表里几千个格子通常只用十来种格式。
final class FormatCodeCache: Sendable {
    static let shared = FormatCodeCache()
    private let storage = Mutex<[ExactText: FormatCode]>([:])

    func parsed(_ code: String) -> FormatCode {
        // literal 要原样显示；规范等价的格式原文也不能串用解析结果。
        let key = ExactText(code)
        if let hit = storage.withLock({ $0[key] }) { return hit }
        let parsed = FormatParser.parse(code)
        storage.withLock { $0[key] = parsed }
        return parsed
    }
}

/// 预设格式：界面菜单里点选，AI 用名字指定（设计第六节）。也可以直接给格式代码。
/// 万元只用 Excel 认得的写法，在 Excel、腾讯文档、WPS 里打开显示一样；代价是只能 1 位小数或者精确到元。
/// 常规（回到没有格式）和千分位两位小数是 2026-10-14 界面加 Format 菜单时补的。
public enum FormatPreset: String, CaseIterable, Sendable {
    case general
    case number
    case cny
    case cnyInteger = "cny_int"
    case wan
    case wanExact = "wan_exact"
    case percent
    case dateChinese = "date_cn"
    case date

    public var code: String {
        switch self {
        case .general: "General"
        case .number: "#,##0.00"
        case .cny: "\"¥\"#,##0.00_);[Red](\"¥\"#,##0.00)"
        case .cnyInteger: "\"¥\"#,##0_);[Red](\"¥\"#,##0)"
        case .wan: "0!.0,\"万\""
        case .wanExact: "0!.0000\"万\""
        case .percent: "0.00%"
        case .dateChinese: "yyyy\"年\"m\"月\"d\"日\""
        case .date: "yyyy/m/d"
        }
    }
}
