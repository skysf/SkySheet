import Foundation

/// 求和、平均、最值、计数。取数规则都在 `Aggregate` 里（设计 5.2 节）。
enum StatisticalFunctions {
    static let all: [FunctionSpec] = [
        FunctionSpec("SUM", 1...FunctionSpec.many, sum),
        FunctionSpec("AVERAGE", 1...FunctionSpec.many, average),
        FunctionSpec("MIN", 1...FunctionSpec.many, minimum),
        FunctionSpec("MAX", 1...FunctionSpec.many, maximum),
        FunctionSpec("COUNT", 1...FunctionSpec.many, count),
        FunctionSpec("COUNTA", 1...FunctionSpec.many, countNonEmpty),
        FunctionSpec("PRODUCT", 1...FunctionSpec.many, product),
        FunctionSpec("SUMPRODUCT", 1...FunctionSpec.many, sumProduct),
        FunctionSpec("RANK", 2...3, rank),
        FunctionSpec("RANK.EQ", 2...3, rank),
    ]

    private static func sum(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        var total: Decimal = 0
        for number in try Aggregate.numbers(arguments) { total += number }
        return .number(try Operators.checked(total))
    }

    private static func average(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        let numbers = try Aggregate.numbers(arguments)
        guard !numbers.isEmpty else { throw CellError.div0 }
        var total: Decimal = 0
        for number in numbers { total += number }
        return .number(try Operators.checked(total / Decimal(numbers.count)))
    }

    /// 一个数都没有时是 0，和 Excel 一样。
    private static func minimum(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        .number(try Aggregate.numbers(arguments).min() ?? 0)
    }

    private static func maximum(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        .number(try Aggregate.numbers(arguments).max() ?? 0)
    }

    private static func count(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        .number(Decimal(Aggregate.countNumbers(arguments)))
    }

    private static func countNonEmpty(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        .number(Decimal(Aggregate.countNonEmpty(arguments)))
    }

    private static func product(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        let numbers = try Aggregate.numbers(arguments)
        guard !numbers.isEmpty else { return .number(0) }
        var result: Decimal = 1
        for number in numbers { result *= number }
        return .number(try Operators.checked(result))
    }

    /// 几块一样大的区域对应位置相乘再求和。不是数字的格子按 0 算；大小不一样是 #VALUE!。
    private static func sumProduct(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        var grids: [Grid] = []
        for index in 0..<arguments.count {
            grids.append(try arguments.grid(index))
        }
        guard let first = grids.first, grids.allSatisfy({ $0.rows == first.rows && $0.columns == first.columns }) else {
            throw CellError.value
        }
        var total: Decimal = 0
        for position in 0..<first.values.count {
            var term: Decimal = 1
            for grid in grids {
                switch grid.values[position] {
                case .number(let number): term *= number
                case .error(let error): throw error
                default: term = 0
                }
            }
            total += term
        }
        return .number(try Operators.checked(total))
    }

    /// RANK(数, 区域, [顺序=0])：在区域的数里排第几，0 从大到小、非 0 从小到大；一样大的同名次。按精确的值比，
    /// 不像 COUNTIF(">"&H2) 要先把数变成 15 位的文字（2026-10-09 端到端时 AI 用 COUNTIF 排名差了一位，所以补上）。
    private static func rank(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        let target = try arguments.number(0)
        let numbers = try arguments.grid(1).values.compactMap { value -> Decimal? in
            if case .number(let number) = value { return number }
            return nil
        }
        guard numbers.contains(target) else { throw CellError.na }
        let ascending = try arguments.integer(2, default: 0) != 0
        return .number(Decimal(numbers.filter { ascending ? $0 < target : $0 > target }.count + 1))
    }
}
