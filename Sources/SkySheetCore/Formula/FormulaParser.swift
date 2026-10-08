import Foundation

/// 公式的语法树。
indirect enum FormulaNode: Equatable, Sendable {
    case number(Decimal)
    case text(String)
    case bool(Bool)
    case error(CellError)
    case reference(ReferenceToken)
    /// 函数里空着的参数，如 PMT(r, n, pv, , 1) 的第 4 个。
    case missing
    case negate(FormulaNode)
    case unaryPlus(FormulaNode)
    case percent(FormulaNode)
    case binary(BinaryOperator, FormulaNode, FormulaNode)
    /// 函数调用。名字已经转成大写、去掉了 `_xlfn.` 这类前缀。
    case call(String, [FormulaNode])
    /// 定义的名称：第一版不支持。
    case name(String)
    /// 引用和函数结果拼成的区域（A1:INDEX(…)）：第一版不支持。
    case dynamicRange(FormulaNode, FormulaNode)
}

enum BinaryOperator: String, Sendable {
    case add = "+", subtract = "-", multiply = "*", divide = "/", power = "^", concat = "&"
    case equal = "=", notEqual = "<>", less = "<", greater = ">", lessOrEqual = "<=", greaterOrEqual = ">="

    /// Excel 的优先级，从低到高：比较 < & < 加减 < 乘除 < 乘方。全部左结合（2^3^2 = 64）。
    var precedence: Int {
        switch self {
        case .equal, .notEqual, .less, .greater, .lessOrEqual, .greaterOrEqual: 1
        case .concat: 2
        case .add, .subtract: 3
        case .multiply, .divide: 4
        case .power: 5
        }
    }
}

/// 按优先级爬升解析。负号比 % 和 ^ 都高：-2^2 = 4，和 Excel 一样。
struct FormulaParser {
    private let tokens: [FormulaToken]
    private var position = 0

    static func parse(_ formula: String) throws(FormulaSyntaxError) -> FormulaNode {
        var parser = FormulaParser(tokens: try FormulaLexer.tokenize(formula))
        guard !parser.tokens.isEmpty else { throw FormulaSyntaxError.unexpectedEnd }
        let node = try parser.expression(minimumPrecedence: 1)
        if let extra = parser.peek { throw FormulaSyntaxError.unexpectedToken(describe(extra)) }
        return node
    }

    /// 函数名统一成大写，去掉 Excel 存新函数时加的前缀（`_xlfn.XLOOKUP`、`_xlfn._xlws.SORT`……）。
    static func canonicalFunctionName(_ name: String) -> String {
        var upper = name.uppercased()
        for prefix in ["_XLFN.", "_XLWS.", "_XLL."] {
            while upper.hasPrefix(prefix) { upper.removeFirst(prefix.count) }
        }
        return upper
    }

    private init(tokens: [FormulaToken]) {
        self.tokens = tokens
    }

    private var peek: FormulaToken.Kind? {
        position < tokens.count ? tokens[position].kind : nil
    }

    private mutating func expression(minimumPrecedence: Int) throws(FormulaSyntaxError) -> FormulaNode {
        var left = try unary()
        while case .op(let symbol)? = peek, let op = BinaryOperator(rawValue: symbol), op.precedence >= minimumPrecedence {
            position += 1
            let right = try expression(minimumPrecedence: op.precedence + 1)
            left = .binary(op, left, right)
        }
        return left
    }

    private mutating func unary() throws(FormulaSyntaxError) -> FormulaNode {
        switch peek {
        case .op("-")?:
            position += 1
            return .negate(try unary())
        case .op("+")?:
            position += 1
            return .unaryPlus(try unary())
        default:
            break
        }
        var node = try primary()
        while case .colon? = peek {
            position += 1
            node = .dynamicRange(node, try primary())
        }
        while case .op("%")? = peek {
            position += 1
            node = .percent(node)
        }
        return node
    }

    private mutating func primary() throws(FormulaSyntaxError) -> FormulaNode {
        guard let kind = peek else { throw FormulaSyntaxError.unexpectedEnd }
        position += 1
        switch kind {
        case .number(let value): return .number(value)
        case .text(let value): return .text(value)
        case .bool(let value): return .bool(value)
        case .error(let value): return .error(value)
        case .reference(let reference): return .reference(reference)
        case .name(let name): return .name(name)
        case .function(let name): return .call(Self.canonicalFunctionName(name), try arguments())
        case .openParen:
            let inner = try expression(minimumPrecedence: 1)
            guard case .closeParen? = peek else { throw FormulaSyntaxError.unexpectedEnd }
            position += 1
            return inner
        case .openBrace:
            throw FormulaSyntaxError.unsupported("array constant")
        default:
            throw FormulaSyntaxError.unexpectedToken(Self.describe(kind))
        }
    }

    /// 函数的参数，"(" 已经吃掉。空着的参数是 `.missing`；`f()` 没有参数。
    private mutating func arguments() throws(FormulaSyntaxError) -> [FormulaNode] {
        if case .closeParen? = peek {
            position += 1
            return []
        }
        var result: [FormulaNode] = []
        while true {
            switch peek {
            case .comma?, .closeParen?: result.append(.missing)
            default: result.append(try expression(minimumPrecedence: 1))
            }
            switch peek {
            case .comma?: position += 1
            case .closeParen?: position += 1; return result
            case let other?: throw FormulaSyntaxError.unexpectedToken(Self.describe(other))
            case nil: throw FormulaSyntaxError.unexpectedEnd
            }
        }
    }

    private static func describe(_ kind: FormulaToken.Kind) -> String {
        switch kind {
        case .op(let symbol): symbol
        case .name(let name), .function(let name): name
        case .comma: ","
        case .colon: ":"
        case .closeParen: ")"
        case .openParen: "("
        case .semicolon: ";"
        case .openBrace: "{"
        case .closeBrace: "}"
        default: "\(kind)"
        }
    }
}
