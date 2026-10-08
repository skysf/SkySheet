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

    /// 数字的「常规」写法（15 位有效数字）。公式里把数字接成文字时用它。
    public static func general(_ number: Decimal) -> String {
        GeneralFormat.render(number)
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
    private let storage = Mutex<[String: FormatCode]>([:])

    func parsed(_ code: String) -> FormatCode {
        if let hit = storage.withLock({ $0[code] }) { return hit }
        let parsed = FormatParser.parse(code)
        storage.withLock { $0[code] = parsed }
        return parsed
    }
}

/// 预设格式：界面菜单里点选，AI 用名字指定（设计第六节）。也可以直接给格式代码。
/// 万元只用 Excel 认得的写法，在 Excel、腾讯文档、WPS 里打开显示一样；代价是只能 1 位小数或者精确到元。
public enum FormatPreset: String, CaseIterable, Sendable {
    case cny
    case cnyInteger = "cny_int"
    case wan
    case wanExact = "wan_exact"
    case percent
    case dateChinese = "date_cn"
    case date

    public var code: String {
        switch self {
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
