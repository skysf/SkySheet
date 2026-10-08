import Foundation

/// 聚合函数怎么取数（Excel 的规则，SUM、AVERAGE、MIN、MAX、PRODUCT、NPV 共用）：
/// - 引用里的格子：只认数字；文字、逻辑值、空格子跳过；错误往上传。
/// - 直接写的参数：数字照算；TRUE / FALSE 算 1 / 0；能转成数字的文字算数字，转不了报 #VALUE!；空着的参数算 0。
enum Aggregate {
    static func numbers(_ arguments: FunctionArguments, from first: Int = 0) throws(CellError) -> [Decimal] {
        var result: [Decimal] = []
        for index in first..<arguments.count {
            switch arguments.values[index] {
            case .missing:
                result.append(0)
            case .value(let value):
                switch value {
                case .number(let number): result.append(number)
                case .bool(let flag): result.append(flag ? 1 : 0)
                case .empty: result.append(0)
                case .error(let error): throw error
                case .text(let text):
                    guard let number = DecimalMath.parse(text) else { throw CellError.value }
                    result.append(number)
                }
            case .area(let area):
                for (_, value) in arguments.context.entries(in: area) {
                    switch value {
                    case .number(let number): result.append(number)
                    case .error(let error): throw error
                    default: continue
                    }
                }
            }
        }
        return result
    }

    /// COUNT：数「数字」。引用里只数数字；直接写的参数里逻辑值和像数字的文字也算。错误不报、不数。
    static func countNumbers(_ arguments: FunctionArguments) -> Int {
        var count = 0
        for argument in arguments.values {
            switch argument {
            case .missing:
                continue
            case .value(let value):
                switch value {
                case .number, .bool: count += 1
                case .text(let text): count += DecimalMath.parse(text) == nil ? 0 : 1
                case .empty, .error: continue
                }
            case .area(let area):
                count += arguments.context.entries(in: area).filter { $0.value.number != nil }.count
            }
        }
        return count
    }

    /// COUNTA：数「不是空的」，错误、空文字（公式返回的 ""）都算。
    static func countNonEmpty(_ arguments: FunctionArguments) -> Int {
        var count = 0
        for argument in arguments.values {
            switch argument {
            case .missing: continue
            case .value(let value): count += value == .empty ? 0 : 1
            case .area(let area): count += arguments.context.entries(in: area).count
            }
        }
        return count
    }
}
