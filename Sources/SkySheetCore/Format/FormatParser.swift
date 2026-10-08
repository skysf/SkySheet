import Foundation

/// 把格式代码解析成 `FormatCode`。不会失败：认不出的字符一律当原样显示的文字（中文 Excel、WPS 里
/// 「元」「万」这类字常常不加引号，也照样认）。
enum FormatParser {
    static func parse(_ code: String) -> FormatCode {
        let sections = splitSections(code).prefix(4).map(parseSection)
        return FormatCode(sections: sections.isEmpty ? [parseSection("General")] : Array(sections))
    }

    /// 按 ";" 分段。引号里、方括号里、转义字符（\ ! _ *）后面的 ";" 不算。
    static func splitSections(_ code: String) -> [String] {
        var sections: [String] = []
        var current = ""
        var inQuotes = false
        var inBrackets = false
        var takeNext = false
        for character in code {
            if takeNext {
                current.append(character)
                takeNext = false
                continue
            }
            switch character {
            case "\"":
                inQuotes.toggle()
            case "[" where !inQuotes:
                inBrackets = true
            case "]" where !inQuotes:
                inBrackets = false
            case "\\", "!", "_", "*":
                takeNext = !inQuotes
            case ";" where !inQuotes && !inBrackets:
                sections.append(current)
                current = ""
                continue
            default:
                break
            }
            current.append(character)
        }
        sections.append(current)
        return sections
    }

    static func parseSection(_ text: String) -> FormatSection {
        var section = FormatSection()
        var builder = TokenBuilder()
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "\"":
                var end = index + 1
                while end < characters.count, characters[end] != "\"" { end += 1 }
                builder.literal(String(characters[(index + 1)..<min(end, characters.count)]))
                index = end + 1
            case "\\", "!":
                if index + 1 < characters.count { builder.literal(String(characters[index + 1])) }
                index += 2
            case "_":
                builder.literal(" ")     // 留出下一个字符那么宽的空白：显示成一个空格
                index += 2
            case "*":
                index += 2               // 用下一个字符填满格子：没有列宽的概念，忽略
            case "[":
                var end = index + 1
                while end < characters.count, characters[end] != "]" { end += 1 }
                bracket(String(characters[(index + 1)..<min(end, characters.count)]), &section, &builder)
                index = end + 1
            case "0": builder.append(.digit(.zero)); index += 1
            case "#": builder.append(.digit(.hash)); index += 1
            case "?": builder.append(.digit(.question)); index += 1
            case ".": builder.append(.decimalPoint); index += 1
            case ",": builder.append(.comma); index += 1
            case "%": builder.append(.percent); index += 1
            case "@": builder.append(.text); index += 1
            case "E", "e":
                // 后面跟 + 或 - 才是科学计数法；单独的 E 当文字。
                // （不能写成 `case "E", "e" where …`：where 只管最后一个模式，大写 E 会漏过去。）
                if index + 1 < characters.count, "+-".contains(characters[index + 1]) {
                    builder.append(.exponent(showsPlus: characters[index + 1] == "+"))
                    index += 2
                } else {
                    index += word(characters, at: index, &builder)
                }
            default:
                index += word(characters, at: index, &builder)
            }
        }
        section.tokens = builder.tokens
        resolveMinutes(&section.tokens)
        resolveSubseconds(&section.tokens)
        classify(&section)
        return section
    }

    /// 关键字和日期字母。返回吃掉了几个字符。
    private static func word(_ characters: [Character], at index: Int, _ builder: inout TokenBuilder) -> Int {
        func starts(_ word: String) -> Bool {
            let end = index + word.count
            return end <= characters.count && String(characters[index..<end]).lowercased() == word.lowercased()
        }
        if starts("General") { builder.append(.general); return 7 }
        if starts("AM/PM") { builder.append(.date(.ampm(.upper))); return 5 }
        if starts("A/P") { builder.append(.date(.ampm(.letter))); return 3 }
        if starts("上午/下午") { builder.append(.date(.ampm(.chinese))); return 5 }

        let character = characters[index]
        let lower = Character(character.lowercased())
        guard "ymdhsa".contains(lower) else {
            builder.literal(String(character))
            return 1
        }
        var run = 1
        while index + run < characters.count, Character(characters[index + run].lowercased()) == lower { run += 1 }
        switch lower {
        case "y": builder.append(.date(.year(run <= 2 ? 2 : 4)))
        case "m": builder.append(.date(.month(min(run, 5))))
        case "d": builder.append(.date(.day(min(run, 4))))
        case "h": builder.append(.date(.hour(min(run, 2))))
        case "s": builder.append(.date(.second(min(run, 2))))
        default:  // "a"：aaa / aaaa 是中文星期，单个 a 当文字
            if run >= 3 {
                builder.append(.date(.chineseWeekday(run >= 4 ? 4 : 3)))
            } else {
                builder.literal(String(repeating: character, count: run))
            }
        }
        return run
    }

    /// 方括号里的东西：颜色、条件、货币 / 地区、经过的时间。别的（如 [DBNum1]）忽略。
    private static func bracket(_ content: String, _ section: inout FormatSection, _ builder: inout TokenBuilder) {
        let lower = content.lowercased()
        let colors = ["black": "Black", "blue": "Blue", "cyan": "Cyan", "green": "Green",
                      "magenta": "Magenta", "red": "Red", "white": "White", "yellow": "Yellow"]
        if let color = colors[lower] {
            section.color = .named(color)
        } else if lower.hasPrefix("color"), let number = Int(lower.dropFirst(5)) {
            section.color = .indexed(number)
        } else if let first = content.first, "<>=".contains(first) {
            section.condition = FormatCondition(content)
        } else if content.hasPrefix("$") {
            // [$¥-804] 显示 "¥"；[$-804] 只是地区标记，不显示东西。
            let symbol = content.dropFirst().split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            if !symbol.isEmpty { builder.literal(String(symbol)) }
        } else if ["h", "hh"].contains(lower) {
            builder.append(.date(.elapsedHours(lower.count)))
        } else if ["m", "mm"].contains(lower) {
            builder.append(.date(.elapsedMinutes(lower.count)))
        } else if ["s", "ss"].contains(lower) {
            builder.append(.date(.elapsedSeconds(lower.count)))
        }
    }

    /// m / mm 跟在小时后面、或者在秒前面时是「分钟」，否则是「月」（Excel 的规则）。
    private static func resolveMinutes(_ tokens: inout [FormatToken]) {
        func dateNeighbor(from index: Int, step: Int) -> DatePart? {
            var position = index + step
            while tokens.indices.contains(position) {
                if case .date(let part) = tokens[position] { return part }
                position += step
            }
            return nil
        }
        for index in tokens.indices {
            guard case .date(.month(let count)) = tokens[index], count <= 2 else { continue }
            switch (dateNeighbor(from: index, step: -1), dateNeighbor(from: index, step: 1)) {
            case (.hour?, _), (.elapsedHours?, _), (_, .second?), (_, .elapsedSeconds?):
                tokens[index] = .date(.minute(count))
            default:
                break
            }
        }
    }

    /// 日期段里 "ss" 后面的 ".00" 是秒的小数。
    private static func resolveSubseconds(_ tokens: inout [FormatToken]) {
        guard let point = tokens.firstIndex(of: .decimalPoint), point > 0 else { return }
        switch tokens[point - 1] {
        case .date(.second), .date(.elapsedSeconds): break
        default: return
        }
        var end = point + 1
        while end < tokens.count, tokens[end] == .digit(.zero) { end += 1 }
        guard end > point + 1 else { return }
        tokens.replaceSubrange(point..<end, with: [.date(.subsecond(end - point - 1))])
    }

    private static func classify(_ section: inout FormatSection) {
        let tokens = section.tokens
        if tokens.contains(where: \.isDate) {
            section.kind = .date
        } else if tokens.contains(where: \.isDigit) {
            section.kind = .number
        } else if tokens.contains(.general) {
            section.kind = .general
        } else if tokens.contains(.text) {
            section.kind = .text
        } else {
            section.kind = .literal
        }
        guard section.kind == .number else { return }

        section.percentCount = tokens.filter { $0 == .percent }.count
        let exponentIndex = tokens.firstIndex(where: \.isExponent) ?? tokens.count
        let integerEnd = tokens.firstIndex(of: .decimalPoint) ?? exponentIndex
        let digitIndices = tokens.indices.filter { tokens[$0].isDigit && $0 < exponentIndex }
        for (index, token) in tokens.enumerated() where token == .comma {
            guard digitIndices.contains(where: { $0 < index }) else { continue }
            if digitIndices.contains(where: { $0 > index && $0 < integerEnd }) {
                section.groupsThousands = true      // 夹在整数位中间：千分位
            } else if !digitIndices.contains(where: { $0 > index }) {
                section.thousandsScale += 1         // 跟在最后一个数字后面：除以 1000
            }
        }
    }
}

/// 攒 token：相邻的文字合成一个。
private struct TokenBuilder {
    var tokens: [FormatToken] = []

    mutating func append(_ token: FormatToken) {
        tokens.append(token)
    }

    mutating func literal(_ text: String) {
        if case .literal(let previous) = tokens.last {
            tokens[tokens.count - 1] = .literal(previous + text)
        } else {
            tokens.append(.literal(text))
        }
    }
}
