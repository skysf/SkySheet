import Foundation
import SkySheetCore

/// 文字最后放在格子的哪边。
public enum HorizontalPlacement: Sendable {
    case left, center, right
}

/// 一个格子要画出来的内容。
public struct DisplayContent: Sendable {
    public enum Kind: Sendable {
        case empty, number, text, bool, error
    }

    public var text: String
    public var kind: Kind
    public var placement: HorizontalPlacement
    public var color: RGBAColor
    /// 数字的原值：列太窄时按「常规」格式缩短要用。
    public var number: Decimal?
    /// 用的是「常规」格式：列太窄时少显示几位小数，而不是变成 ###。
    public var isGeneralNumber: Bool
}

/// 格子显示成什么（设计 8.2 节）：文字、放在哪边、什么颜色；数字放不下怎么办；文字往旁边空格子溢出到哪。
public enum CellDisplay {
    public static func content(of cell: Cell, style: ResolvedStyle, dateSystem: DateSystem) -> DisplayContent {
        let formatted = ValueFormatter.format(cell.value, code: style.formatCode, dateSystem: dateSystem)
        let color = formatted.color.flatMap(ColorResolver.formatColor) ?? style.font.color
        let kind: DisplayContent.Kind = switch cell.value {
        case .empty: .empty
        case .number: .number
        case .text: .text
        case .bool: .bool
        case .error: .error
        }
        let general = style.formatCode.caseInsensitiveCompare("General") == .orderedSame
        return DisplayContent(text: formatted.text, kind: kind, placement: placement(kind, style.horizontal),
                              color: color, number: cell.value.number, isGeneralNumber: general && kind == .number)
    }

    /// 「常规」对齐：数字（含日期）靠右，文字靠左，逻辑值和错误居中。和 Excel 一样。
    static func placement(_ kind: DisplayContent.Kind, _ alignment: HorizontalAlignment) -> HorizontalPlacement {
        switch alignment {
        case .left, .fill, .justify, .distributed: return .left
        case .center, .centerContinuous: return .center
        case .right: return .right
        case .general:
            switch kind {
            case .number: return .right
            case .bool, .error: return .center
            case .text, .empty: return .left
            }
        }
    }

    /// 数字放不下 `width` 时：「常规」格式先少显示几位小数（整数部分不动），整数都放不下就改成科学计数法；
    /// 别的格式、或者怎么都放不下，就是一串 #。和 Excel 一样。`measure` 量一段文字有多宽。
    public static func fitNumber(_ content: DisplayContent, width: Double, measure: (String) -> Double) -> String {
        guard content.kind == .number, measure(content.text) > width else { return content.text }
        if content.isGeneralNumber, let number = content.number, number != 0 {
            let magnitude = abs(number)
            let integerDigits = magnitude >= 1 ? DecimalMath.exponent10(magnitude) + 1 : 1
            let significant = magnitude >= 1 ? integerDigits : -DecimalMath.exponent10(magnitude)
            for decimals in stride(from: max(0, 15 - integerDigits), through: 0, by: -1) {
                let rounded = DecimalMath.round(number, scale: decimals)
                // 小数砍到只剩不到两位有效数字（0.000001），不如科学计数法（1.23E-06）。
                if magnitude < 1, decimals < significant + 1 { break }
                let candidate = DecimalMath.plainString(rounded)
                if measure(candidate) <= width { return candidate }
            }
            for decimals in stride(from: 5, through: 0, by: -1) {
                let candidate = scientific(number, decimals: decimals)
                if measure(candidate) <= width { return candidate }
            }
        }
        let hashWidth = max(measure("#"), 0.1)
        return String(repeating: "#", count: max(1, Int(width / hashWidth)))
    }

    /// 1.23E+11 这样的写法，小数位末尾的 0 去掉，指数至少两位。
    static func scientific(_ number: Decimal, decimals: Int) -> String {
        let exponent = DecimalMath.exponent10(abs(number))
        var mantissa = DecimalMath.round(number / DecimalMath.powerOfTen(exponent), scale: decimals)
        var power = exponent
        if abs(mantissa) >= 10 {
            mantissa /= 10
            power += 1
        }
        let digits = String(abs(power))
        return DecimalMath.plainString(mantissa) + "E" + (power < 0 ? "-" : "+") + (digits.count < 2 ? "0" : "") + digits
    }

    /// 文字比列宽长时，能占到哪几列：靠左的往右占，靠右的往左占，居中的两边各占一半；
    /// 只能占空格子（旁边有东西就截断在那里）。返回占到的列区间，`limit` 防止无限往右找。
    public static func overflowColumns(column: Int, textWidth: Double, placement: HorizontalPlacement,
                                       columnWidth: (Int) -> Double, isEmpty: (Int) -> Bool,
                                       columnCount: Int, limit: Int = 64) -> ClosedRange<Int> {
        var first = column
        var last = column
        let own = columnWidth(column)
        guard textWidth > own else { return first...last }
        func extendRight(_ needed: Double) {
            var covered = 0.0
            while covered < needed, last + 1 < columnCount, last - column < limit, isEmpty(last + 1) {
                last += 1
                covered += columnWidth(last)
            }
        }
        func extendLeft(_ needed: Double) {
            var covered = 0.0
            while covered < needed, first > 0, column - first < limit, isEmpty(first - 1) {
                first -= 1
                covered += columnWidth(first)
            }
        }
        switch placement {
        case .left: extendRight(textWidth - own)
        case .right: extendLeft(textWidth - own)
        case .center:
            extendLeft((textWidth - own) / 2)
            extendRight((textWidth - own) / 2)
        }
        return first...last
    }
}

/// 状态栏上选中区域的合计（和 Excel 底部那行一样）：有几个非空格子、几个数字、合计、平均。
public struct SelectionSummary: Equatable, Sendable {
    public var count = 0
    public var numericCount = 0
    public var sum: Decimal = 0

    public var average: Decimal? {
        numericCount > 0 ? sum / Decimal(numericCount) : nil
    }

    public init(cells: SparseGrid<Cell>, range: CellRange) {
        for (_, cell) in cells.entries(in: range) where cell.value != .empty {
            count += 1
            if let number = cell.value.number {
                numericCount += 1
                sum += number
            }
        }
    }
}
