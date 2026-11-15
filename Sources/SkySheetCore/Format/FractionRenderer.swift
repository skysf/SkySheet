import Foundation

/// 分母位数决定最接近的有理数：?/? 到 9，??/?? 到 99。整数部分仍用共用的占位符渲染。
enum FractionRenderer {
    static func render(_ magnitude: Decimal, tokens: [FormatToken], slash: Int) -> String {
        var numeratorStart = slash
        while numeratorStart > 0, tokens[numeratorStart - 1].isDigit { numeratorStart -= 1 }
        var denominatorEnd = slash + 1
        while denominatorEnd < tokens.count, tokens[denominatorEnd].isDigit { denominatorEnd += 1 }
        let numeratorTokens = Array(tokens[numeratorStart..<slash])
        let denominatorTokens = Array(tokens[(slash + 1)..<denominatorEnd])
        // 格式来自文件，不能让几百个 ? 造成无界搜索或 10ⁿ 溢出；内置格式只用一、二位。
        guard !numeratorTokens.isEmpty, (1...4).contains(denominatorTokens.count) else { return DateRenderer.invalid }
        let prefix = Array(tokens[..<numeratorStart])
        let mixed = prefix.contains(where: \.isDigit)
        var whole = mixed ? DecimalMath.floor(magnitude) : 0
        let fraction = magnitude - DecimalMath.floor(magnitude)
        let maximum = [9, 99, 999, 9999][denominatorTokens.count - 1]
        var numerator = 0
        var denominator = 1
        var bestDistance = Decimal(1)
        for candidate in 1...maximum {
            let rounded = DecimalMath.round(fraction * Decimal(candidate), scale: 0)
            let distance = abs(fraction - rounded / Decimal(candidate))
            if distance < bestDistance {
                numerator = DecimalMath.int(rounded) ?? 0
                denominator = candidate
                bestDistance = distance
                if distance == 0 { break }
            }
        }
        if mixed, numerator == denominator {
            whole += 1
            numerator = 0
        }
        let amount = mixed ? Decimal(numerator) : DecimalMath.floor(magnitude) * Decimal(denominator) + Decimal(numerator)
        let hidden = mixed && numerator == 0 && !numeratorTokens.contains(.digit(.zero))
        let left = NumberRenderer.fixed(whole, tokens: prefix, groupsThousands: prefix.contains(.comma))
        let top = digits(hidden ? "" : DecimalMath.plainString(amount), tokens: numeratorTokens, alignLeft: false)
        let bottom = digits(hidden ? "" : String(denominator), tokens: denominatorTokens, alignLeft: true)
        let suffix = NumberRenderer.fixed(0, tokens: Array(tokens[denominatorEnd...]), groupsThousands: false)
        return left + top + (hidden ? " " : "/") + bottom + suffix
    }

    /// ? 补空格；分子右对齐、分母左对齐，使不同位数的分数沿斜杠排齐。
    private static func digits(_ text: String, tokens: [FormatToken], alignLeft: Bool) -> String {
        let padding = tokens.dropFirst(min(text.count, tokens.count)).map { token in
            token == .digit(.zero) ? "0" : token == .digit(.question) ? " " : ""
        }.joined()
        return alignLeft ? text + padding : padding + text
    }
}
