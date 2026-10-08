import Foundation

/// SUMIF、COUNTIF 这类函数的一个条件：5、TRUE、">=100"、"<>"、"中信*"……（设计 5.2 节 Criteria）。
struct Criterion {
    enum Comparison {
        case equal, notEqual, less, lessOrEqual, greater, greaterOrEqual
    }

    let comparison: Comparison
    /// `.empty` 表示和空格子比（条件写成 "" 或 "=" 或 "<>"）。
    let operand: CellValue

    init(_ criterion: CellValue) {
        guard case .text(let text) = criterion else {
            comparison = .equal
            operand = criterion == .empty ? .empty : criterion
            return
        }
        let symbols: [(String, Comparison)] = [("<=", .lessOrEqual), (">=", .greaterOrEqual), ("<>", .notEqual),
                                               ("<", .less), (">", .greater), ("=", .equal)]
        let (symbol, comparison) = symbols.first { text.hasPrefix($0.0) } ?? ("", .equal)
        let rest = String(text.dropFirst(symbol.count))
        self.comparison = comparison
        if rest.isEmpty {
            operand = .empty
        } else if let number = DecimalMath.parse(rest) {
            operand = .number(number)
        } else if rest.uppercased() == "TRUE" || rest.uppercased() == "FALSE" {
            operand = .bool(rest.uppercased() == "TRUE")
        } else {
            operand = .text(rest)
        }
    }

    func matches(_ value: CellValue) -> Bool {
        switch operand {
        case .empty:
            let blank = value == .empty || value == .text("")
            switch comparison {
            case .equal: return blank
            case .notEqual: return !blank
            default: return false
            }
        case .number(let target):
            var candidate = value.number
            // 等于 / 不等于时，像数字的文字也算（COUNTIF(A:A, 10) 也数到文字 "10"）。
            if candidate == nil, case .text(let text) = value, comparison == .equal || comparison == .notEqual {
                candidate = DecimalMath.parse(text)
            }
            guard let candidate else { return comparison == .notEqual }
            return holds(candidate < target ? .orderedAscending : (candidate > target ? .orderedDescending : .orderedSame))
        case .text(let pattern):
            guard case .text(let text) = value else { return comparison == .notEqual }
            switch comparison {
            case .equal: return Wildcard.matches(text, pattern: pattern)
            case .notEqual: return !Wildcard.matches(text, pattern: pattern)
            default: return holds(text.compare(pattern, options: .caseInsensitive))
            }
        case .bool, .error:
            switch comparison {
            case .equal: return value == operand
            case .notEqual: return value != operand
            default: return false
            }
        }
    }

    private func holds(_ order: ComparisonResult) -> Bool {
        switch comparison {
        case .equal: order == .orderedSame
        case .notEqual: order != .orderedSame
        case .less: order == .orderedAscending
        case .lessOrEqual: order != .orderedDescending
        case .greater: order == .orderedDescending
        case .greaterOrEqual: order != .orderedAscending
        }
    }
}

/// Excel 的通配符：* 任意多个字符，? 一个字符，~ 让下一个字符按原样比（~* 就是星号本身）。不分大小写。
enum Wildcard {
    private enum Piece: Equatable {
        case any
        case one
        case character(Character)
    }

    static func matches(_ text: String, pattern: String) -> Bool {
        let characters = Array(text.lowercased())
        var pieces: [Piece] = []
        var escaped = false
        for character in pattern.lowercased() {
            if escaped {
                pieces.append(.character(character))
                escaped = false
            } else if character == "~" {
                escaped = true
            } else {
                pieces.append(character == "*" ? .any : (character == "?" ? .one : .character(character)))
            }
        }
        if escaped { pieces.append(.character("~")) }

        // 经典的贪心加回溯：记住最近一个 * 的位置，对不上就让它多吃一个字符。
        var textIndex = 0
        var pieceIndex = 0
        var starPiece = -1
        var starText = 0
        while textIndex < characters.count {
            if pieceIndex < pieces.count,
               pieces[pieceIndex] == .one || pieces[pieceIndex] == .character(characters[textIndex]) {
                textIndex += 1
                pieceIndex += 1
            } else if pieceIndex < pieces.count, pieces[pieceIndex] == .any {
                starPiece = pieceIndex
                starText = textIndex
                pieceIndex += 1
            } else if starPiece >= 0 {
                pieceIndex = starPiece + 1
                starText += 1
                textIndex = starText
            } else {
                return false
            }
        }
        while pieceIndex < pieces.count, pieces[pieceIndex] == .any { pieceIndex += 1 }
        return pieceIndex == pieces.count
    }
}
