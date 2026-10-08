import Foundation

/// 年金公式（等额本息）。PMT、IPMT、PPMT、PV、FV、NPER、RATE、CUMIPMT、CUMPRINC 都用它，只是解的未知数不同。
///
/// 记号和 Excel 一样：rate 每期利率，periods 期数，payment 每期付款，present 现值，future 终值，type 0 期末付 / 1 期初付。
/// 钱流出是负数、流入是正数。它们满足
///     present·(1+r)^n + payment·(1+r·type)·((1+r)^n − 1)/r + future = 0
/// 迭代和指数运算用 Double，和 Excel 一样（设计 5.4 节）。
enum Annuity {
    /// 上面那个等式左边的值。RATE 求的就是让它等于 0 的 r。r 趋于 0 时取极限：present + payment·n + future。
    static func balance(rate: Double, periods: Double, payment: Double, present: Double, future: Double,
                        type: Double) -> Double {
        if abs(rate) < 1e-12 { return present + payment * periods + future }
        let growth = pow(1 + rate, periods)
        return present * growth + payment * (1 + rate * type) * (growth - 1) / rate + future
    }

    static func payment(rate: Double, periods: Double, present: Double, future: Double, type: Double) -> Double {
        if rate == 0 { return -(present + future) / periods }
        let growth = pow(1 + rate, periods)
        return -(future + present * growth) * rate / ((1 + rate * type) * (growth - 1))
    }

    static func futureValue(rate: Double, periods: Double, payment: Double, present: Double, type: Double) -> Double {
        if rate == 0 { return -(present + payment * periods) }
        let growth = pow(1 + rate, periods)
        return -(present * growth + payment * (1 + rate * type) * (growth - 1) / rate)
    }

    static func presentValue(rate: Double, periods: Double, payment: Double, future: Double, type: Double) -> Double {
        if rate == 0 { return -(future + payment * periods) }
        let growth = pow(1 + rate, periods)
        return -(future + payment * (1 + rate * type) * (growth - 1) / rate) / growth
    }

    static func periods(rate: Double, payment: Double, present: Double, future: Double, type: Double) throws(CellError) -> Double {
        if rate == 0 {
            guard payment != 0 else { throw CellError.num }
            return -(present + future) / payment
        }
        let adjusted = payment * (1 + rate * type)
        let ratio = (adjusted - future * rate) / (adjusted + present * rate)
        guard ratio > 0, ratio.isFinite else { throw CellError.num }
        return log(ratio) / log(1 + rate)
    }

    /// 第 `period` 期付的利息（IPMT）。算法和 LibreOffice 的一样：上一期期末的余额乘利率。
    static func interest(rate: Double, period: Double, periods: Double, present: Double, future: Double,
                         type: Double) -> Double {
        let payment = payment(rate: rate, periods: periods, present: present, future: future, type: type)
        let balance: Double
        if period == 1 {
            balance = type == 1 ? 0 : -present
        } else if type == 1 {
            balance = futureValue(rate: rate, periods: period - 2, payment: payment, present: present, type: 1) - payment
        } else {
            balance = futureValue(rate: rate, periods: period - 1, payment: payment, present: present, type: 0)
        }
        return balance * rate
    }
}
