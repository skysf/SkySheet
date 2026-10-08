import Foundation

/// 数学函数。Decimal 精确算；开方用 Double（设计 5.4 节）。
enum MathFunctions {
    static let all: [FunctionSpec] = [
        FunctionSpec("ROUND", 2...2, rounded),
        FunctionSpec("ROUNDUP", 2...2, roundedUp),
        FunctionSpec("ROUNDDOWN", 2...2, roundedDown),
        FunctionSpec("INT", 1...1, integerPart),
        FunctionSpec("ABS", 1...1, absoluteValue),
        FunctionSpec("MOD", 2...2, modulo),
        FunctionSpec("SQRT", 1...1, squareRoot),
        FunctionSpec("POWER", 2...2, raised),
    ]

    /// 遇 5 远离零：ROUND(-2.5, 0) = -3。位数可以是负的：ROUND(1234, -2) = 1200。
    private static func rounded(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        .number(DecimalMath.round(try arguments.number(0), scale: try arguments.integer(1)))
    }

    private static func roundedUp(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        .number(DecimalMath.roundAwayFromZero(try arguments.number(0), scale: try arguments.integer(1)))
    }

    private static func roundedDown(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        .number(DecimalMath.truncate(try arguments.number(0), scale: try arguments.integer(1)))
    }

    /// 向下取整（往负无穷）：INT(-2.5) = -3。
    private static func integerPart(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        .number(DecimalMath.floor(try arguments.number(0)))
    }

    private static func absoluteValue(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        .number(abs(try arguments.number(0)))
    }

    /// 结果的符号跟除数：MOD(-3, 2) = 1，MOD(3, -2) = -1。Decimal 算 MOD(0.3, 0.1) 就是 0（Double 会得到 0.09999…）。
    private static func modulo(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        let number = try arguments.number(0)
        let divisor = try arguments.number(1)
        guard divisor != 0 else { throw CellError.div0 }
        return .number(try Operators.checked(number - divisor * DecimalMath.floor(number / divisor)))
    }

    private static func squareRoot(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        let number = try arguments.number(0)
        guard number >= 0, let root = DecimalMath.decimal(sqrt(DecimalMath.double(number))) else { throw CellError.num }
        return .number(root)
    }

    private static func raised(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        .number(try Operators.power(try arguments.number(0), try arguments.number(1)))
    }
}
