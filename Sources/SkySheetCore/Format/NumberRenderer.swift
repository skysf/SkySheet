import Foundation

/// 按数字段渲染（设计第六节）。
enum NumberRenderer {
    static func render(_ value: Decimal, section: FormatSection, showMinus: Bool) -> String {
        var magnitude = abs(value)
        for _ in 0..<section.percentCount { magnitude *= 100 }
        for _ in 0..<section.thousandsScale { magnitude /= 1000 }
        let body: String
        if let exponentIndex = section.tokens.firstIndex(where: \.isExponent) {
            body = scientific(magnitude, tokens: section.tokens, exponentIndex: exponentIndex)
        } else {
            body = fixed(magnitude, tokens: section.tokens, groupsThousands: section.groupsThousands)
        }
        return showMinus ? "-" + body : body
    }

    /// 定点写法。数字按占位符从右往左填：整数位多出来的数字全给最左边那个占位符；占位符之间的文字照原位置插进去
    /// （`0!.0,"万"` 把 489 填成 "48" "." "9"，显示 48.9万）。
    static func fixed(_ magnitude: Decimal, tokens: [FormatToken], groupsThousands: Bool) -> String {
        let decimalIndex = tokens.firstIndex(of: .decimalPoint)
        let integerSlots = tokens.indices.filter { index in tokens[index].isDigit && (decimalIndex.map { index < $0 } ?? true) }
        let fractionSlots = tokens.indices.filter { index in tokens[index].isDigit && (decimalIndex.map { index > $0 } ?? false) }

        let rounded = DecimalMath.round(magnitude, scale: fractionSlots.count)
        let (integerDigits, fractionDigits) = split(rounded, fractionCount: fractionSlots.count)
        var output: [Int: String] = [:]

        var pending = Array(integerDigits)
        for (position, slot) in integerSlots.reversed().enumerated() {
            if position == integerSlots.count - 1 {
                output[slot] = pending.isEmpty ? empty(tokens[slot]) : String(pending)
                pending = []
            } else if let digit = pending.popLast() {
                output[slot] = String(digit)
            } else {
                output[slot] = empty(tokens[slot])
            }
        }
        if groupsThousands, let first = integerSlots.first {
            let joined = integerSlots.map { output[$0] ?? "" }.joined()
            integerSlots.forEach { output[$0] = "" }
            output[first] = groupThousands(joined)
        }

        // 小数末尾的 0：# 不显示，? 显示成空格，碰到 0 占位符或者非零数字就停。
        let fraction = fractionDigits.map(String.init)
        var trimming = true
        for (position, slot) in fractionSlots.enumerated().reversed() {
            let digit = fraction[position]
            if trimming, digit == "0", tokens[slot] != .digit(.zero) {
                output[slot] = tokens[slot] == .digit(.question) ? " " : ""
                continue
            }
            trimming = false
            output[slot] = digit
        }

        var result = ""
        for (index, token) in tokens.enumerated() {
            switch token {
            case .literal(let text): result += text
            case .digit: result += output[index] ?? ""
            case .decimalPoint where index == decimalIndex:
                // 格式里没有整数占位符（如 ".00"）时，整数部分照样要显示出来。
                result += (integerSlots.isEmpty ? integerDigits : "") + "."
            case .decimalPoint: result += "."
            case .percent: result += "%"
            case .general: result += GeneralFormat.render(magnitude)
            case .comma, .text, .date, .exponent: break
            }
        }
        return result
    }

    /// 科学计数法（`0.00E+00`；整数位有好几个占位符的，如 `##0.0E+0`，指数取它的倍数）。
    private static func scientific(_ magnitude: Decimal, tokens: [FormatToken], exponentIndex: Int) -> String {
        let mantissaTokens = Array(tokens[..<exponentIndex])
        let exponentTokens = tokens[(exponentIndex + 1)...]
        let decimalIndex = mantissaTokens.firstIndex(of: .decimalPoint) ?? mantissaTokens.count
        let integerPlaces = max(1, mantissaTokens[..<decimalIndex].filter(\.isDigit).count)
        let fractionPlaces = mantissaTokens[decimalIndex...].filter(\.isDigit).count
        let step = integerPlaces > 1 ? integerPlaces : 1

        var exponent = 0
        var mantissa = magnitude
        if magnitude != 0 {
            let natural = DecimalMath.exponent10(magnitude)
            exponent = Int((Double(natural) / Double(step)).rounded(.down)) * step
            mantissa = magnitude / DecimalMath.powerOfTen(exponent)
            if DecimalMath.round(mantissa, scale: fractionPlaces) >= DecimalMath.powerOfTen(step) {
                exponent += step
                mantissa = magnitude / DecimalMath.powerOfTen(exponent)
            }
        }
        let zeroPlaces = max(1, exponentTokens.filter { $0 == .digit(.zero) }.count)
        let digits = String(abs(exponent))
        var showsPlus = true
        if case .exponent(let plus) = tokens[exponentIndex] { showsPlus = plus }
        let sign = exponent < 0 ? "-" : (showsPlus ? "+" : "")
        return fixed(mantissa, tokens: mantissaTokens, groupsThousands: false)
            + "E" + sign + String(repeating: "0", count: max(0, zeroPlaces - digits.count)) + digits
    }

    /// 拆成整数位（不带前导 0，小于 1 时是空串）和正好 `fractionCount` 位的小数位。
    static func split(_ value: Decimal, fractionCount: Int) -> (String, String) {
        let plain = DecimalMath.plainString(value)
        let parts = plain.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let integer = parts[0] == "0" ? "" : String(parts[0])
        var fraction = parts.count > 1 ? String(parts[1]) : ""
        fraction = String(fraction.prefix(fractionCount))
        fraction += String(repeating: "0", count: fractionCount - fraction.count)
        return (integer, fraction)
    }

    private static func empty(_ token: FormatToken) -> String {
        switch token {
        case .digit(.zero): "0"
        case .digit(.question): " "
        default: ""
        }
    }

    /// 给一串数字加千分位，前面的空格（? 占位符留的）原样保留。
    static func groupThousands(_ text: String) -> String {
        let prefix = text.prefix { !$0.isNumber }
        let digits = Array(text.dropFirst(prefix.count))
        var grouped = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { grouped.append(",") }
            grouped.append(digit)
        }
        return prefix + grouped
    }
}

/// Excel 的「常规」：最多 15 位有效数字，去掉末尾的 0；绝对值 ≥ 1E+15 或者 < 1E-9（不为 0）时用科学计数法。
/// 公式里把数字接成文字（="合计"&A1）也是这个写法。界面上按列宽再缩短是 M2 的事。
enum GeneralFormat {
    static func render(_ value: Decimal, significantDigits: Int = 15) -> String {
        guard value != 0 else { return "0" }
        let rounded = DecimalMath.roundSignificant(value, digits: significantDigits)
        let magnitude = abs(rounded)
        guard magnitude >= DecimalMath.powerOfTen(15) || magnitude < DecimalMath.powerOfTen(-9) else {
            return DecimalMath.plainString(rounded)
        }
        let exponent = DecimalMath.exponent10(magnitude)
        let mantissa = DecimalMath.plainString(rounded / DecimalMath.powerOfTen(exponent))
        let digits = String(abs(exponent))
        return mantissa + "E" + (exponent < 0 ? "-" : "+") + (digits.count < 2 ? "0" : "") + digits
    }
}
