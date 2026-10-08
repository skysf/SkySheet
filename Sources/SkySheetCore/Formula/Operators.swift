import Foundation

/// Excel 的类型转换（设计 5.4 节）。
enum Coercion {
    /// 算术里的转数字：空格子是 0，TRUE / FALSE 是 1 / 0，文字要整个是数（"1,234"、"abc" 都是 #VALUE!）。
    static func number(_ value: CellValue) throws(CellError) -> Decimal {
        switch value {
        case .number(let number): return number
        case .empty: return 0
        case .bool(let flag): return flag ? 1 : 0
        case .text(let text):
            guard let number = DecimalMath.parse(text) else { throw CellError.value }
            return number
        case .error(let error): throw error
        }
    }

    /// 接成文字：数字按「常规」写（15 位有效数字），逻辑值是 TRUE / FALSE，空格子是空串。
    static func text(_ value: CellValue) throws(CellError) -> String {
        switch value {
        case .text(let text): return text
        case .number(let number): return GeneralFormat.render(number)
        case .bool(let flag): return flag ? "TRUE" : "FALSE"
        case .empty: return ""
        case .error(let error): throw error
        }
    }

    /// 当条件用：数字非 0 为真；文字只认 "TRUE" / "FALSE"。
    static func bool(_ value: CellValue) throws(CellError) -> Bool {
        switch value {
        case .bool(let flag): return flag
        case .number(let number): return number != 0
        case .empty: return false
        case .text(let text):
            switch text.uppercased() {
            case "TRUE": return true
            case "FALSE": return false
            default: throw CellError.value
            }
        case .error(let error): throw error
        }
    }
}

enum Operators {
    static func apply(_ op: BinaryOperator, _ left: CellValue, _ right: CellValue) -> CellValue {
        // 两边都有错误时，Excel 报左边那个。
        if case .error(let error) = left { return .error(error) }
        if case .error(let error) = right { return .error(error) }
        do throws(CellError) {
            switch op {
            case .add: return .number(try checked(try Coercion.number(left) + Coercion.number(right)))
            case .subtract: return .number(try checked(try Coercion.number(left) - Coercion.number(right)))
            case .multiply: return .number(try checked(try Coercion.number(left) * Coercion.number(right)))
            case .divide:
                let dividend = try Coercion.number(left)
                let divisor = try Coercion.number(right)
                guard divisor != 0 else { throw CellError.div0 }
                return .number(try checked(dividend / divisor))
            case .power: return .number(try power(try Coercion.number(left), try Coercion.number(right)))
            case .concat: return .text(try Coercion.text(left) + Coercion.text(right))
            case .equal: return .bool(compare(left, right) == .orderedSame)
            case .notEqual: return .bool(compare(left, right) != .orderedSame)
            case .less: return .bool(compare(left, right) == .orderedAscending)
            case .greater: return .bool(compare(left, right) == .orderedDescending)
            case .lessOrEqual: return .bool(compare(left, right) != .orderedDescending)
            case .greaterOrEqual: return .bool(compare(left, right) != .orderedAscending)
            }
        } catch {
            return .error(error)
        }
    }

    static func negate(_ value: CellValue) -> CellValue {
        do throws(CellError) {
            return .number(-(try Coercion.number(value)))
        } catch {
            return .error(error)
        }
    }

    static func percent(_ value: CellValue) -> CellValue {
        do throws(CellError) {
            return .number(try Coercion.number(value) / 100)
        } catch {
            return .error(error)
        }
    }

    /// 乘方。整数次方用 Decimal 精确算（1.0025^360 不丢精度）；分数次方用 Double。
    /// 0^0 和负数开分数次方是 #NUM!，0 的负数次方是 #DIV/0!，和 Excel 一样。
    static func power(_ base: Decimal, _ exponent: Decimal) throws(CellError) -> Decimal {
        if base == 0 {
            if exponent == 0 { throw CellError.num }
            if exponent < 0 { throw CellError.div0 }
            return 0
        }
        if DecimalMath.isInteger(exponent), let n = DecimalMath.int(exponent), abs(n) <= 1024 {
            var result = Decimal()
            var input = base
            guard NSDecimalPower(&result, &input, abs(n), .plain) == .noError else { throw CellError.num }
            return n < 0 ? try checked(1 / result) : result
        }
        guard base > 0 || DecimalMath.isInteger(exponent) else { throw CellError.num }
        guard let result = DecimalMath.decimal(pow(DecimalMath.double(base), DecimalMath.double(exponent))) else {
            throw CellError.num
        }
        return result
    }

    /// Decimal 溢出时得到 NaN：报 #NUM!。
    static func checked(_ value: Decimal) throws(CellError) -> Decimal {
        guard !value.isNaN else { throw CellError.num }
        return value
    }

    /// Excel 的比较：类型不同时 数字 < 文字 < 逻辑值；空格子跟着对方的类型（和数字比当 0，和文字比当 ""，和逻辑值比当 FALSE）；
    /// 文字不分大小写。
    static func compare(_ left: CellValue, _ right: CellValue) -> ComparisonResult {
        let a = blankAs(left, against: right)
        let b = blankAs(right, against: left)
        switch (a, b) {
        case (.number(let x), .number(let y)):
            return x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
        case (.text(let x), .text(let y)):
            return x.compare(y, options: .caseInsensitive)
        case (.bool(let x), .bool(let y)):
            return x == y ? .orderedSame : (x ? .orderedDescending : .orderedAscending)
        default:
            let (rankA, rankB) = (rank(a), rank(b))
            return rankA < rankB ? .orderedAscending : (rankA > rankB ? .orderedDescending : .orderedSame)
        }
    }

    private static func blankAs(_ value: CellValue, against other: CellValue) -> CellValue {
        guard value == .empty else { return value }
        switch other {
        case .text: return .text("")
        case .bool: return .bool(false)
        default: return .number(0)
        }
    }

    private static func rank(_ value: CellValue) -> Int {
        switch value {
        case .number, .empty: 0
        case .text: 1
        case .bool: 2
        case .error: 3
        }
    }
}
