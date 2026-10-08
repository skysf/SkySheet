import Foundation

/// 贷款与理财函数（设计 5.3 节）。算法在 `Annuity`、`RootSolver`、`CashFlow` 里，这里只取参、校验、登记。
/// 钱的方向和 Excel 一样：付出去是负数，收进来是正数。
enum FinancialFunctions {
    static let all: [FunctionSpec] = [
        FunctionSpec("PMT", 3...5, payment),
        FunctionSpec("IPMT", 4...6, interestPayment),
        FunctionSpec("PPMT", 4...6, principalPayment),
        FunctionSpec("PV", 3...5, presentValue),
        FunctionSpec("FV", 3...5, futureValue),
        FunctionSpec("NPER", 3...5, periods),
        FunctionSpec("RATE", 3...6, rate),
        FunctionSpec("NPV", 2...FunctionSpec.many, netPresentValue),
        FunctionSpec("XNPV", 3...3, datedNetPresentValue),
        FunctionSpec("IRR", 1...2, internalRate),
        FunctionSpec("XIRR", 2...3, datedInternalRate),
        FunctionSpec("CUMIPMT", 6...6, cumulativeInterest),
        FunctionSpec("CUMPRINC", 6...6, cumulativePrincipal),
        FunctionSpec("EFFECT", 2...2, effectiveRate),
        FunctionSpec("NOMINAL", 2...2, nominalRate),
    ]

    /// PMT(利率, 期数, 现值, [终值], [类型])：每期还多少（等额本息）。
    private static func payment(_ a: FunctionArguments) throws(CellError) -> CellValue {
        let periods = try a.double(1)
        guard periods != 0 else { throw CellError.num }
        return try result(Annuity.payment(rate: try a.double(0), periods: periods, present: try a.double(2),
                                          future: try a.double(3, default: 0), type: try type(a, 4)))
    }

    /// IPMT(利率, 第几期, 期数, 现值, [终值], [类型])：那一期还的利息。
    private static func interestPayment(_ a: FunctionArguments) throws(CellError) -> CellValue {
        let (rate, period, periods, present, future, type) = try periodArguments(a)
        return try result(Annuity.interest(rate: rate, period: period, periods: periods, present: present,
                                           future: future, type: type))
    }

    /// PPMT：那一期还的本金 = 每期还款 − 那一期的利息。
    private static func principalPayment(_ a: FunctionArguments) throws(CellError) -> CellValue {
        let (rate, period, periods, present, future, type) = try periodArguments(a)
        let total = Annuity.payment(rate: rate, periods: periods, present: present, future: future, type: type)
        let interest = Annuity.interest(rate: rate, period: period, periods: periods, present: present,
                                        future: future, type: type)
        return try result(total - interest)
    }

    private static func presentValue(_ a: FunctionArguments) throws(CellError) -> CellValue {
        try result(Annuity.presentValue(rate: try a.double(0), periods: try a.double(1), payment: try a.double(2),
                                        future: try a.double(3, default: 0), type: try type(a, 4)))
    }

    private static func futureValue(_ a: FunctionArguments) throws(CellError) -> CellValue {
        try result(Annuity.futureValue(rate: try a.double(0), periods: try a.double(1), payment: try a.double(2),
                                       present: try a.double(3, default: 0), type: try type(a, 4)))
    }

    private static func periods(_ a: FunctionArguments) throws(CellError) -> CellValue {
        try result(try Annuity.periods(rate: try a.double(0), payment: try a.double(1), present: try a.double(2),
                                       future: try a.double(3, default: 0), type: try type(a, 4)))
    }

    /// RATE(期数, 每期付款, 现值, [终值], [类型], [猜测=10%])：每期利率。年化要自己乘 12（样例 J 列就是这么写的）。
    private static func rate(_ a: FunctionArguments) throws(CellError) -> CellValue {
        let periods = try a.double(0)
        guard periods > 0 else { throw CellError.num }
        let (payment, present) = (try a.double(1), try a.double(2))
        let (future, type) = (try a.double(3, default: 0), try type(a, 4))
        let root = try RootSolver.solve(guess: try a.double(5, default: 0.1), lower: -1 + 1e-10, upper: 10) { rate in
            Annuity.balance(rate: rate, periods: periods, payment: payment, present: present, future: future, type: type)
        }
        return try result(root)
    }

    /// NPV(利率, 值1, …)：第一笔也折现一期（Excel 的定义，和很多教科书不同）。
    private static func netPresentValue(_ a: FunctionArguments) throws(CellError) -> CellValue {
        let rate = try a.double(0)
        guard rate != -1 else { throw CellError.div0 }
        let values = try Aggregate.numbers(a, from: 1).map(DecimalMath.double)
        return try result(CashFlow.presentValue(rate: rate, values: values, firstPeriod: 1))
    }

    private static func datedNetPresentValue(_ a: FunctionArguments) throws(CellError) -> CellValue {
        let rate = try a.double(0)
        let (values, days) = try datedFlows(a, values: 1, dates: 2)
        return try result(CashFlow.datedPresentValue(rate: rate, values: values, days: days))
    }

    /// IRR(一串现金流, [猜测])：至少一正一负，否则 #NUM!。区域里不是数字的格子跳过。
    private static func internalRate(_ a: FunctionArguments) throws(CellError) -> CellValue {
        let values = try a.grid(0).values.compactMap { value -> Double? in value.number.map(DecimalMath.double) }
        try requireBothSigns(values)
        let root = try RootSolver.solve(guess: try a.double(1, default: 0.1), lower: -1 + 1e-10, upper: 1e6) { rate in
            CashFlow.presentValue(rate: rate, values: values, firstPeriod: 0)
        }
        return try result(root)
    }

    /// XIRR(现金流, 日期, [猜测])：按实际日子算的年化收益率，定投这类不定期的现金流就用它。
    private static func datedInternalRate(_ a: FunctionArguments) throws(CellError) -> CellValue {
        let (values, days) = try datedFlows(a, values: 0, dates: 1)
        try requireBothSigns(values)
        let root = try RootSolver.solve(guess: try a.double(2, default: 0.1), lower: -1 + 1e-10, upper: 1e6) { rate in
            CashFlow.datedPresentValue(rate: rate, values: values, days: days)
        }
        return try result(root)
    }

    /// CUMIPMT(利率, 期数, 现值, 起始期, 结束期, 类型)：这几期一共还的利息（负数）。
    private static func cumulativeInterest(_ a: FunctionArguments) throws(CellError) -> CellValue {
        try result(try cumulative(a).interest)
    }

    /// CUMPRINC：这几期一共还的本金（负数）。
    private static func cumulativePrincipal(_ a: FunctionArguments) throws(CellError) -> CellValue {
        try result(try cumulative(a).principal)
    }

    /// EFFECT(名义年利率, 每年复利次数)：实际年利率。
    private static func effectiveRate(_ a: FunctionArguments) throws(CellError) -> CellValue {
        let nominal = try a.double(0)
        let count = Double(try a.integer(1))
        guard nominal > 0, count >= 1 else { throw CellError.num }
        return try result(pow(1 + nominal / count, count) - 1)
    }

    private static func nominalRate(_ a: FunctionArguments) throws(CellError) -> CellValue {
        let effective = try a.double(0)
        let count = Double(try a.integer(1))
        guard effective > 0, count >= 1 else { throw CellError.num }
        return try result(count * (pow(1 + effective, 1 / count) - 1))
    }

    // MARK: - 共用的部分

    private static func result(_ value: Double) throws(CellError) -> CellValue {
        guard let decimal = DecimalMath.decimal(value) else { throw CellError.num }
        return .number(decimal)
    }

    /// 类型参数：0 期末付，非 0 都当 1（期初付）。
    private static func type(_ a: FunctionArguments, _ index: Int) throws(CellError) -> Double {
        try a.double(index, default: 0) != 0 ? 1 : 0
    }

    private static func periodArguments(_ a: FunctionArguments) throws(CellError)
        -> (Double, Double, Double, Double, Double, Double) {
        let period = try a.double(1)
        let periods = try a.double(2)
        guard period >= 1, period <= periods else { throw CellError.num }
        return (try a.double(0), period, periods, try a.double(3), try a.double(4, default: 0), try type(a, 5))
    }

    /// 一段期间里每期利息和本金的合计：就是逐期的 IPMT、PPMT 加起来（同一个 Annuity.interest）。
    private static func cumulative(_ a: FunctionArguments) throws(CellError) -> (interest: Double, principal: Double) {
        let (rate, periods, present) = (try a.double(0), try a.double(1), try a.double(2))
        let (first, last) = (try a.integer(3), try a.integer(4))
        let typeValue = try a.number(5)
        guard rate > 0, periods > 0, present > 0, first >= 1, last >= first, Double(last) <= periods,
              typeValue == 0 || typeValue == 1 else { throw CellError.num }
        let type = DecimalMath.double(typeValue)
        let payment = Annuity.payment(rate: rate, periods: periods, present: present, future: 0, type: type)
        var interest = 0.0
        var principal = 0.0
        for period in first...last {
            let part = Annuity.interest(rate: rate, period: Double(period), periods: periods, present: present,
                                        future: 0, type: type)
            interest += part
            principal += payment - part
        }
        return (interest, principal)
    }

    /// XNPV、XIRR 的现金流和日期：个数要一样，都得是数字；日期不能早于第一笔。
    private static func datedFlows(_ a: FunctionArguments, values: Int, dates: Int) throws(CellError)
        -> ([Double], [Double]) {
        let amounts = try a.grid(values).values
        let days = try a.grid(dates).values
        guard amounts.count == days.count, !amounts.isEmpty else { throw CellError.num }
        var resultAmounts: [Double] = []
        var resultDays: [Double] = []
        for (amount, day) in zip(amounts, days) {
            guard let value = amount.number, let date = day.number else { throw CellError.value }
            resultAmounts.append(DecimalMath.double(value))
            resultDays.append(DecimalMath.double(DecimalMath.floor(date)))
        }
        guard let start = resultDays.first, resultDays.allSatisfy({ $0 >= start }) else { throw CellError.num }
        return (resultAmounts, resultDays)
    }

    private static func requireBothSigns(_ values: [Double]) throws(CellError) {
        guard values.contains(where: { $0 > 0 }), values.contains(where: { $0 < 0 }) else { throw CellError.num }
    }
}
