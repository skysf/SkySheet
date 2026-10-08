import Foundation

/// 公式里的一个词。`range` 是它在原文里的位置：平移引用时按位置替换，别的字符一个不动（设计 5.1 节）。
struct FormulaToken: Equatable {
    enum Kind: Equatable {
        case number(Decimal)
        case text(String)
        case bool(Bool)
        case error(CellError)
        case reference(ReferenceToken)
        /// 函数名，原样（含 `_xlfn.` 这类前缀）。后面紧跟的 "(" 已经吃掉。
        case function(String)
        /// 定义的名称，或者别的认不出的名字。第一版不支持。
        case name(String)
        case op(String)
        case openParen, closeParen, comma, colon
        /// 数组常量 {1,2;3,4} 用到的。第一版不支持。
        case openBrace, closeBrace, semicolon
    }

    let kind: Kind
    let range: Range<String.Index>
}

/// 一个引用：单个格子、一块区域、整列（A:B）或整行（1:3），可以带 sheet 名。
public struct ReferenceToken: Hashable, Sendable {
    /// sheet 名，引号已经去掉；nil 表示公式所在的那张 sheet。
    public var sheet: String?
    public var start: ReferencePoint
    /// 区域的另一角。单个格子时是 nil。
    public var end: ReferencePoint?
}

/// 引用的一个角。整列引用时 `row` 是 nil，整行引用时 `column` 是 nil。
public struct ReferencePoint: Hashable, Sendable {
    public var row: Int?
    public var column: Int?
    public var rowAbsolute: Bool
    public var columnAbsolute: Bool
}

public enum FormulaSyntaxError: Error, Equatable, Sendable {
    case unexpectedCharacter(String)
    case unterminatedText
    case unexpectedToken(String)
    case unexpectedEnd
    /// 语法对，但第一版不支持（数组常量、结构化引用、三维引用……）。
    case unsupported(String)
}

extension ReferenceToken {
    /// 解析成区域。整列 / 整行引用铺满整张表的行或列。
    var range: CellRange {
        let first = CellAddress(row: start.row ?? 0, column: start.column ?? 0)
        guard let end else { return CellRange(first) }
        let last = CellAddress(row: end.row ?? CellAddress.maxRows - 1, column: end.column ?? CellAddress.maxColumns - 1)
        return CellRange(first, last)
    }
}
