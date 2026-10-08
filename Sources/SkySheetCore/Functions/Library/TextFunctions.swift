import Foundation

/// 文字函数。按字符（Character）数，中文一个字算一个。
enum TextFunctions {
    static let all: [FunctionSpec] = [
        FunctionSpec("TEXT", 2...2, text),
        FunctionSpec("CONCAT", 1...FunctionSpec.many, concat),
        FunctionSpec("CONCATENATE", 1...FunctionSpec.many, concatenate),
        FunctionSpec("LEFT", 1...2, left),
        FunctionSpec("RIGHT", 1...2, right),
        FunctionSpec("MID", 3...3, middle),
        FunctionSpec("LEN", 1...1, length),
    ]

    /// TEXT(值, 格式)：和格子按这个格式显示出来的一样（同一个 ValueFormatter）。像数字的文字先转成数字。
    private static func text(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        var value = arguments.scalar(0)
        if case .error(let error) = value { throw error }
        if case .text(let text) = value, let number = DecimalMath.parse(text) { value = .number(number) }
        let code = try arguments.text(1)
        return .text(ValueFormatter.format(value, code: code, dateSystem: arguments.context.dateSystem).text)
    }

    /// CONCAT 可以给区域，按行优先接起来；CONCATENATE 是老函数，区域按隐式交集取一格。
    private static func concat(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        var result = ""
        for argument in arguments.values {
            switch argument {
            case .missing: continue
            case .value(let value): result += try Coercion.text(value)
            case .area(let area):
                for (_, value) in arguments.context.entries(in: area) { result += try Coercion.text(value) }
            }
        }
        return .text(result)
    }

    private static func concatenate(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        var result = ""
        for index in 0..<arguments.count { result += try arguments.text(index) }
        return .text(result)
    }

    private static func left(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        let count = try arguments.integer(1, default: 1)
        guard count >= 0 else { throw CellError.value }
        return .text(String(try arguments.text(0).prefix(count)))
    }

    private static func right(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        let count = try arguments.integer(1, default: 1)
        guard count >= 0 else { throw CellError.value }
        return .text(String(try arguments.text(0).suffix(count)))
    }

    /// MID(文字, 从第几个起, 取几个)，从 1 数起。
    private static func middle(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        let start = try arguments.integer(1)
        let count = try arguments.integer(2)
        guard start >= 1, count >= 0 else { throw CellError.value }
        return .text(String(try arguments.text(0).dropFirst(start - 1).prefix(count)))
    }

    private static func length(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        .number(Decimal(try arguments.text(0).count))
    }
}
