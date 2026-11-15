import Foundation

/// 连分数只走收敛项，成本随分母上限的对数增长；不能为每个格子枚举上万个分母。
enum FractionRenderer {
    static func render(_ magnitude: Decimal, tokens: [FormatToken], slash: Int) -> String {
        var numeratorStart = slash
        while numeratorStart > 0, tokens[numeratorStart - 1].isDigit { numeratorStart -= 1 }
        var denominatorEnd = slash + 1
        while denominatorEnd < tokens.count, tokens[denominatorEnd].isDigit { denominatorEnd += 1 }
        let numeratorTokens = Array(tokens[numeratorStart..<slash])
        var fixed: Int?
        if slash + 1 < tokens.count, case .fixedDenominator(let text) = tokens[slash + 1] {
            guard text.count <= 4, let number = Int(text), number > 0 else { return DateRenderer.invalid }
            fixed = number
            denominatorEnd = slash + 2
        }
        let denominatorTokens = fixed == nil ? Array(tokens[(slash + 1)..<denominatorEnd]) : []
        guard !numeratorTokens.isEmpty, fixed != nil || (1...4).contains(denominatorTokens.count) else { return DateRenderer.invalid }
        let prefix = Array(tokens[..<numeratorStart])
        let mixed = prefix.contains(where: \.isDigit)
        let integer = DecimalMath.floor(magnitude)
        var whole = mixed ? integer : 0
        let fraction = DecimalMath.double(magnitude - integer)
        var (numerator, denominator) = fixed.map { (Int((fraction * Double($0)).rounded()), $0) }
            ?? nearest(fraction, maximum: [9, 99, 999, 9999][denominatorTokens.count - 1])
        if mixed, numerator == denominator {
            whole += 1
            numerator = 0
        }
        let amount = mixed ? Decimal(numerator) : integer * Decimal(denominator) + Decimal(numerator)
        let hidden = mixed && numerator == 0 && !numeratorTokens.contains(.digit(.zero))
        let left = NumberRenderer.fixed(whole, tokens: prefix, groupsThousands: prefix.contains(.comma))
        let top = digits(hidden ? "" : DecimalMath.plainString(amount), tokens: numeratorTokens)
        let bottom: String
        if let fixed {
            bottom = hidden ? String(repeating: " ", count: String(fixed).count) : String(fixed)
        } else {
            bottom = digits(hidden ? "" : String(denominator), tokens: denominatorTokens, denominator: true)
        }
        let suffix = NumberRenderer.fixed(0, tokens: Array(tokens[denominatorEnd...]), groupsThousands: false)
        return left + top + (hidden ? " " : "/") + bottom + suffix
    }

    /// 最后一个收敛项与边界半收敛项之间择近；收敛项互质，不会因浮点末位把 16/113 写成 80/565。
    private static func nearest(_ value: Double, maximum: Int) -> (Int, Int) {
        var x = value
        var (p0, q0, p1, q1) = (0, 1, 1, 0)
        while true {
            let integral = x.rounded(.down)
            if q1 > 0, integral > Double((maximum - q0) / q1) { break }
            let a = Int(integral)
            let (p2, q2) = (p0 + a * p1, q0 + a * q1)
            (p0, q0, p1, q1) = (p1, q1, p2, q2)
            let remainder = x - integral
            if remainder < 1e-14 { return (p1, q1) }
            x = 1 / remainder
        }
        let k = (maximum - q0) / q1
        let (p, q) = (p0 + k * p1, q0 + k * q1)
        return abs(Double(p1) / Double(q1) - value) <= abs(Double(p) / Double(q) - value) ? (p1, q1) : (p, q)
    }

    /// 分母左对齐，? 在右边补空格；0 始终补前导零，00/00 的 3/2 因而是 03/02。
    private static func digits(_ text: String, tokens: [FormatToken], denominator: Bool = false) -> String {
        let padding = tokens.dropFirst(min(text.count, tokens.count))
        let zeros = padding.filter { $0 == .digit(.zero) }.count
        let spaces = padding.filter { $0 == .digit(.question) }.count
        return denominator ? String(repeating: "0", count: zeros) + text + String(repeating: " ", count: spaces)
            : String(repeating: " ", count: spaces) + String(repeating: "0", count: zeros) + text
    }
}
