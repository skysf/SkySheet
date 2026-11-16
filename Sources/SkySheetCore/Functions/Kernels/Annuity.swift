import Foundation

/// 年金公式（等额本息）。PMT、IPMT、PPMT、PV、FV、NPER、RATE、CUMIPMT、CUMPRINC 都用它，只是解的未知数不同。
///
/// 记号和 Excel 一样：rate 每期利率，periods 期数，payment 每期付款，present 现值，future 终值，type 0 期末付 / 1 期初付。
/// 钱流出是负数、流入是正数。它们满足
///     present·(1+r)^n + payment·(1+r·type)·((1+r)^n − 1)/r + future = 0
/// 迭代和指数运算用 Double，和 Excel 一样（设计 5.4 节）。
enum Annuity {
    /// 把本金等比数列除以总增长因子，指数始终非正；避免 payment + present·rate 的消减误差被放大。
    static func cumulativePrincipal(rate: Double, periods: Double, payment: Double, present: Double,
                                    first: Int, last: Int, type: Double) -> Double {
        let start = type == 1 ? max(2, first) : first
        var result = type == 1 && first == 1 ? payment : 0
        if start <= last {
            let logarithm = log1p(rate)
            let exponent = -remaining(periods: periods, after: last) - type
            let count = Double(last - start + 1)
            result -= present * exp(exponent * logarithm) * (-expm1(-count * logarithm))
                / (-expm1(-periods * logarithm))
        }
        return result
    }

    /// 累计利息直接按「上期余额 × 利率」求和，不用「付款总额 − 本金」：利率极小时利息比这两个数小几十个数量级，
    /// 相减会把有效位丢光（1e-25、500 期、现值 1e30 的第一期会算成 0，IPMT 是 −100000）。
    ///
    /// 记 L = ln(1+r)、E(x) = 1 − e^(−x)。期末付第 k 期利息是 −r·P·E((n−k+1)L)/E(nL)；第 first…last 期合起来，
    /// 指数 j 从 p = n−last+1 连续取 m 个，Σ E(jL) = D + E(pL)·X，X = E(mL)/E(L)，D = m − X ≥ 0，各项都非负。
    /// 期初付第 1 期没有利息，之后每期是期末付同一期的 1/(1+r)。只有一期时 D = 0、X = 1，结果与 IPMT 同为 −r·P·E(pL)/E(nL)。
    static func cumulativeInterest(rate: Double, periods: Double, present: Double, first: Int, last: Int,
                                   type: Double) -> Double {
        let start = type == 1 ? max(2, first) : first
        guard start <= last else { return 0 }
        let logarithm = log1p(rate)
        let count = Double(last - start + 1)
        let geometric = decay(count * logarithm) / decay(logarithm)
        let sum = deficit(count: count, logarithm: logarithm, geometric: geometric)
            + decay((remaining(periods: periods, after: last) + 1) * logarithm) * geometric
        let interest = -rate * present * (sum / decay(periods * logarithm))
        return type == 1 ? interest / (1 + rate) : interest
    }

    /// periods − last 要精确：last 超过 2^53 时 Double(last) 会并到相邻的整数（1e16 − 1 变成 1e16），尾期就算成了
    /// 别的期。期数是 Int 范围内的整数时按整数相减；带小数的期数都小于 2^52，不超过它的 last 转 Double 本来就精确。
    static func remaining(periods: Double, after last: Int) -> Double {
        guard periods.rounded(.towardZero) == periods, abs(periods) < 0x1p63 else { return periods - Double(last) }
        return Double(Int(periods) - last)
    }

    /// E(x) = 1 − e^(−x)，小 x 也不丢位。
    private static func decay(_ x: Double) -> Double { -expm1(-x) }

    /// D = m − X。mL 小时 X 和 m 几乎相等，直接相减会丢位；改写成 D = L²·(m²·φ(mL) − m·φ(L))/E(L)，
    /// 括号里两项之比约为 m，最多丢一位；先乘 L、再乘 L/E(L)，L² 极小时也不会下溢成 0。
    private static func deficit(count: Double, logarithm: Double, geometric: Double) -> Double {
        guard count * logarithm <= 1 else { return count - geometric }
        let bracket = count * count * phi(count * logarithm) - count * phi(logarithm)
        return logarithm * bracket * (logarithm / decay(logarithm))
    }

    /// φ(x) = (x − E(x))/x² = Σ (−x)^(k−2)/k!（k ≥ 2）。只在 0 ≤ x ≤ 1 用，20 项后余项小于 1e−20。
    private static func phi(_ x: Double) -> Double {
        var term = 0.5
        var sum = term
        for k in 3...22 {
            term *= -x / Double(k)
            sum += term
        }
        return sum
    }

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
