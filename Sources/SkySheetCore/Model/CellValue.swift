import Foundation

/// 一个格子的值。和 Excel 一样，日期也是数字（序列号）加上日期格式，没有单独的日期类型。
public enum CellValue: Hashable, Sendable {
    case empty
    /// 用 Decimal 而不是 Double：金额分毫不差，0.1 + 0.2 就是 0.3（设计第 9 条）。
    case number(Decimal)
    case text(String)
    case bool(Bool)
    case error(CellError)

    public var number: Decimal? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var isEmpty: Bool { self == .empty }
}

/// Excel 的错误值。也用作公式求值时抛出的错误（`throws(CellError)`），抛出来的就是格子里要显示的那个。
public enum CellError: Error, Hashable, Sendable, CustomStringConvertible {
    case null       // #NULL!
    case div0       // #DIV/0!
    case value      // #VALUE!
    case ref        // #REF!
    case name       // #NAME?
    case num        // #NUM!
    case na         // #N/A
    /// 循环引用。Excel 显示 0 再弹警告；SkySheet 在格子里明确标出来，保存时不写缓存值（设计 5.5 节）。
    case circular
    /// 文件里读到的、我们不认识的错误码（#SPILL!、#CALC! 等）：原样显示、原样写回。
    case other(String)

    public init(code: String) {
        switch code.uppercased() {
        case "#NULL!": self = .null
        case "#DIV/0!": self = .div0
        case "#VALUE!": self = .value
        case "#REF!": self = .ref
        case "#NAME?": self = .name
        case "#NUM!": self = .num
        case "#N/A": self = .na
        default: self = .other(code)
        }
    }

    public var code: String {
        switch self {
        case .null: "#NULL!"
        case .div0: "#DIV/0!"
        case .value: "#VALUE!"
        case .ref: "#REF!"
        case .name: "#NAME?"
        case .num: "#NUM!"
        case .na: "#N/A"
        case .circular: "#CIRC!"
        case .other(let code): code
        }
    }

    public var description: String { code }
}
