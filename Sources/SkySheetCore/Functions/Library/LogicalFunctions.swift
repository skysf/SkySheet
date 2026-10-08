import Foundation

enum LogicalFunctions {
    static let all: [FunctionSpec] = [
        FunctionSpec("IF", 1...3, ifThenElse),
        FunctionSpec("AND", 1...FunctionSpec.many, all),
        FunctionSpec("OR", 1...FunctionSpec.many, any),
        FunctionSpec("NOT", 1...1, not),
        FunctionSpec("IFERROR", 2...2, ifError),
        FunctionSpec("IFS", 2...FunctionSpec.many, ifs),
    ]

    /// IF(条件, [真], [假])。参数写了但空着算 0；「假」干脆没写时返回 FALSE。和 Excel 一样。
    private static func ifThenElse(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        let condition = try Coercion.bool(arguments.scalar(0))
        let branch = condition ? 1 : 2
        guard branch < arguments.count else { return .bool(condition) }
        return arguments.isOmitted(branch) ? .number(0) : arguments.scalar(branch)
    }

    private static func all(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        .bool(try logicals(arguments).allSatisfy { $0 })
    }

    private static func any(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        .bool(try logicals(arguments).contains(true))
    }

    private static func not(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        .bool(!(try Coercion.bool(arguments.scalar(0))))
    }

    private static func ifError(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        let value = arguments.scalar(0)
        if case .error = value { return arguments.scalar(1) }
        return value
    }

    /// IFS(条件1, 值1, 条件2, 值2, …)：第一个成立的条件对应的值；都不成立是 #N/A。
    private static func ifs(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        guard arguments.count % 2 == 0 else { throw CellError.value }
        for index in stride(from: 0, to: arguments.count, by: 2) {
            if try Coercion.bool(arguments.scalar(index)) { return arguments.scalar(index + 1) }
        }
        throw CellError.na
    }

    /// AND / OR 取逻辑值：引用里只认逻辑值和数字（文字、空格子跳过）；直接写的文字只认 "TRUE" / "FALSE"。
    /// 一个逻辑值都没有是 #VALUE!。
    private static func logicals(_ arguments: FunctionArguments) throws(CellError) -> [Bool] {
        var result: [Bool] = []
        for argument in arguments.values {
            switch argument {
            case .missing:
                result.append(false)
            case .value(let value):
                if value != .empty { result.append(try Coercion.bool(value)) }
            case .area(let area):
                for (_, value) in arguments.context.entries(in: area) {
                    switch value {
                    case .bool(let flag): result.append(flag)
                    case .number(let number): result.append(number != 0)
                    case .error(let error): throw error
                    default: continue
                    }
                }
            }
        }
        guard !result.isEmpty else { throw CellError.value }
        return result
    }
}
