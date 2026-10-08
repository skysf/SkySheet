import Foundation

/// 把公式原文切成词（不带开头的 "="）。
struct FormulaLexer {
    private let scalars: [Unicode.Scalar]
    /// 每个 scalar 在原文里的位置，最后多一个 endIndex：词的 range 由它换算。
    private let indices: [String.Index]
    private var position = 0

    private static let errorCodes = ["#NULL!", "#DIV/0!", "#VALUE!", "#REF!", "#NAME?", "#NUM!", "#N/A",
                                     "#GETTING_DATA", "#SPILL!", "#CALC!", "#FIELD!", "#BLOCKED!",
                                     "#CONNECT!", "#BUSY!", "#UNKNOWN!"]

    init(_ source: String) {
        var scalars: [Unicode.Scalar] = []
        var indices: [String.Index] = []
        var index = source.unicodeScalars.startIndex
        while index < source.unicodeScalars.endIndex {
            scalars.append(source.unicodeScalars[index])
            indices.append(index)
            index = source.unicodeScalars.index(after: index)
        }
        indices.append(source.endIndex)
        self.scalars = scalars
        self.indices = indices
    }

    static func tokenize(_ source: String) throws(FormulaSyntaxError) -> [FormulaToken] {
        var lexer = FormulaLexer(source)
        var tokens: [FormulaToken] = []
        while let token = try lexer.next() {
            tokens.append(token)
        }
        return tokens
    }

    private mutating func next() throws(FormulaSyntaxError) -> FormulaToken? {
        while position < scalars.count, Self.isWhitespace(scalars[position]) { position += 1 }
        guard position < scalars.count else { return nil }
        let start = position
        let character = scalars[position]
        switch character {
        case "\"": return try text()
        case "#": return try errorLiteral()
        case "'": return try quotedSheetReference()
        case "(": return punctuation(.openParen)
        case ")": return punctuation(.closeParen)
        case ",": return punctuation(.comma)
        case ":": return punctuation(.colon)
        case "{": return punctuation(.openBrace)
        case "}": return punctuation(.closeBrace)
        case ";": return punctuation(.semicolon)
        case "+", "-", "*", "/", "^", "&", "%", "=":
            return punctuation(.op(String(character)))
        case "<", ">":
            let next = scalar(at: position + 1)
            if next == "=" || (character == "<" && next == ">") {
                position += 2
                return token(.op(String(character) + String(next!)), from: start)
            }
            return punctuation(.op(String(character)))
        default:
            if let (reference, end) = matchReference(at: position, sheet: nil) {
                position = end
                return token(.reference(reference), from: start)
            }
            if Self.isDigit(character) || character == "." { return try number() }
            if Self.isIdentifierStart(character) { return try identifier() }
            throw FormulaSyntaxError.unexpectedCharacter(String(character))
        }
    }

    // MARK: - 各种词

    private mutating func text() throws(FormulaSyntaxError) -> FormulaToken {
        let start = position
        position += 1
        var value = String.UnicodeScalarView()
        while true {
            guard let character = scalar(at: position) else { throw FormulaSyntaxError.unterminatedText }
            position += 1
            if character == "\"" {
                guard scalar(at: position) == "\"" else { break }   // "" 是一个引号
                position += 1
            }
            value.append(character)
        }
        return token(.text(String(value)), from: start)
    }

    private mutating func errorLiteral() throws(FormulaSyntaxError) -> FormulaToken {
        let start = position
        let rest = String(String.UnicodeScalarView(scalars[position...].prefix(16))).uppercased()
        guard let code = Self.errorCodes.first(where: { rest.hasPrefix($0) }) else {
            throw FormulaSyntaxError.unexpectedCharacter("#")
        }
        position += code.unicodeScalars.count
        return token(.error(CellError(code: code)), from: start)
    }

    private mutating func number() throws(FormulaSyntaxError) -> FormulaToken {
        let start = position
        skipDigits()
        if scalar(at: position) == "." {
            position += 1
            skipDigits()
        }
        if let e = scalar(at: position), e == "e" || e == "E" {
            let sign = scalar(at: position + 1)
            let digitAt = sign == "+" || sign == "-" ? position + 2 : position + 1
            if let digit = scalar(at: digitAt), Self.isDigit(digit) {
                position = digitAt
                skipDigits()
            }
        }
        let literal = String(String.UnicodeScalarView(scalars[start..<position]))
        guard let value = DecimalMath.parse(literal) else { throw FormulaSyntaxError.unexpectedCharacter(literal) }
        return token(.number(value), from: start)
    }

    /// 名字：函数（后面跟 "("）、sheet 名（后面跟 "!"）、TRUE / FALSE，或者定义的名称。
    private mutating func identifier() throws(FormulaSyntaxError) -> FormulaToken {
        let start = position
        while let character = scalar(at: position), Self.isIdentifierContinue(character) { position += 1 }
        let name = String(String.UnicodeScalarView(scalars[start..<position]))
        switch scalar(at: position) {
        case "!":
            position += 1
            return try sheetQualified(name, from: start)
        case "(":
            position += 1
            return token(.function(name), from: start)
        case "[":
            throw FormulaSyntaxError.unsupported("structured reference \(name)[…]")
        default:
            switch name.uppercased() {
            case "TRUE": return token(.bool(true), from: start)
            case "FALSE": return token(.bool(false), from: start)
            default: return token(.name(name), from: start)
            }
        }
    }

    /// 'sheet 名'!A1：引号里的 '' 是一个单引号。
    private mutating func quotedSheetReference() throws(FormulaSyntaxError) -> FormulaToken {
        let start = position
        position += 1
        var name = String.UnicodeScalarView()
        while true {
            guard let character = scalar(at: position) else { throw FormulaSyntaxError.unterminatedText }
            position += 1
            if character == "'" {
                guard scalar(at: position) == "'" else { break }
                position += 1
            }
            name.append(character)
        }
        guard scalar(at: position) == "!" else { throw FormulaSyntaxError.unexpectedToken("'\(String(name))'") }
        position += 1
        return try sheetQualified(String(name), from: start)
    }

    /// "!" 后面：引用，或者 #REF!（指向已删除区域的公式就长这样）。
    private mutating func sheetQualified(_ sheet: String, from start: Int) throws(FormulaSyntaxError) -> FormulaToken {
        if let (reference, end) = matchReference(at: position, sheet: sheet) {
            position = end
            return token(.reference(reference), from: start)
        }
        if scalar(at: position) == "#" {
            let error = try errorLiteral()
            return FormulaToken(kind: error.kind, range: indices[start]..<error.range.upperBound)
        }
        throw FormulaSyntaxError.unexpectedToken("\(sheet)!")
    }

    // MARK: - 引用

    /// 在 `start` 处认一个引用：A1、A1:B2、A:B、1:3（都可以带 $）。后面紧跟字母数字、"("、"!" 的不算（如 LOG10(、R2D2）。
    private func matchReference(at start: Int, sheet: String?) -> (ReferenceToken, Int)? {
        if let (first, afterFirst) = cellPart(at: start) {
            if scalar(at: afterFirst) == ":", let (second, afterSecond) = cellPart(at: afterFirst + 1),
               isBoundary(afterSecond) {
                return (ReferenceToken(sheet: sheet, start: first, end: second), afterSecond)
            }
            if isBoundary(afterFirst) {
                return (ReferenceToken(sheet: sheet, start: first, end: nil), afterFirst)
            }
        }
        if let (first, afterFirst) = columnPart(at: start), scalar(at: afterFirst) == ":",
           let (second, afterSecond) = columnPart(at: afterFirst + 1), isBoundary(afterSecond) {
            return (ReferenceToken(sheet: sheet, start: first, end: second), afterSecond)
        }
        if let (first, afterFirst) = rowPart(at: start), scalar(at: afterFirst) == ":",
           let (second, afterSecond) = rowPart(at: afterFirst + 1), isBoundary(afterSecond) {
            return (ReferenceToken(sheet: sheet, start: first, end: second), afterSecond)
        }
        return nil
    }

    private func cellPart(at start: Int) -> (ReferencePoint, Int)? {
        guard let (column, afterColumn) = columnPart(at: start), let (row, afterRow) = rowPart(at: afterColumn) else {
            return nil
        }
        return (ReferencePoint(row: row.row, column: column.column, rowAbsolute: row.rowAbsolute,
                               columnAbsolute: column.columnAbsolute), afterRow)
    }

    /// $?字母{1,3}，而且后面不能再跟字母（否则是函数名之类）。
    private func columnPart(at start: Int) -> (ReferencePoint, Int)? {
        var index = start
        let absolute = scalar(at: index) == "$"
        if absolute { index += 1 }
        let lettersStart = index
        while let character = scalar(at: index), CellAddress.isASCIILetter(character), index - lettersStart < 4 {
            index += 1
        }
        guard index > lettersStart, index - lettersStart <= 3,
              let column = CellAddress.columnIndex(String(String.UnicodeScalarView(scalars[lettersStart..<index])))
        else { return nil }
        return (ReferencePoint(row: nil, column: column, rowAbsolute: false, columnAbsolute: absolute), index)
    }

    /// $?数字，1 到 1,048,576。
    private func rowPart(at start: Int) -> (ReferencePoint, Int)? {
        var index = start
        let absolute = scalar(at: index) == "$"
        if absolute { index += 1 }
        let digitsStart = index
        while let character = scalar(at: index), Self.isDigit(character) { index += 1 }
        guard index > digitsStart, index - digitsStart <= 7,
              let number = Int(String(String.UnicodeScalarView(scalars[digitsStart..<index]))),
              (1...CellAddress.maxRows).contains(number)
        else { return nil }
        return (ReferencePoint(row: number - 1, column: nil, rowAbsolute: absolute, columnAbsolute: false), index)
    }

    private func isBoundary(_ index: Int) -> Bool {
        guard let character = scalar(at: index) else { return true }
        return !Self.isIdentifierContinue(character) && character != "(" && character != "!"
    }

    // MARK: - 小工具

    private func scalar(at index: Int) -> Unicode.Scalar? {
        index < scalars.count ? scalars[index] : nil
    }

    private mutating func skipDigits() {
        while let character = scalar(at: position), Self.isDigit(character) { position += 1 }
    }

    private mutating func punctuation(_ kind: FormulaToken.Kind) -> FormulaToken {
        position += 1
        return token(kind, from: position - 1)
    }

    private func token(_ kind: FormulaToken.Kind, from start: Int) -> FormulaToken {
        FormulaToken(kind: kind, range: indices[start]..<indices[position])
    }

    static func isDigit(_ character: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(character)
    }

    static func isWhitespace(_ character: Unicode.Scalar) -> Bool {
        character == " " || character == "\n" || character == "\r" || character == "\t" || character == "\u{00A0}"
    }

    /// 名字可以用字母（包括中文）、下划线、反斜杠开头。
    static func isIdentifierStart(_ character: Unicode.Scalar) -> Bool {
        character == "_" || character == "\\" || character.properties.isAlphabetic
    }

    static func isIdentifierContinue(_ character: Unicode.Scalar) -> Bool {
        isIdentifierStart(character) || isDigit(character) || character == "."
    }
}
