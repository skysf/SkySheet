import Foundation

/// 求 f(x) = 0 的根：RATE、IRR、XIRR 共用（设计 5.2 节）。
///
/// 先从 guess 出发用牛顿法（导数用中心差分）；不收敛，就在 (lower, upper) 里找一段变号的区间再二分。
/// Excel 只做牛顿法、20 次不收敛就报 #NUM!；我们更稳：区间里有根就给出来，实在找不到才是 #NUM!。
/// 精度比腾讯文档、Excel 更高：样例里腾讯文档的 RATE 和精确解差到 6.5e-11（设计 5.6 节）。
enum RootSolver {
    static func solve(guess: Double, lower: Double, upper: Double, _ f: (Double) -> Double) throws(CellError) -> Double {
        if let root = newton(from: guess, lower: lower, upper: upper, f) { return root }
        if let root = bisection(lower: lower, upper: upper, near: guess, f) { return root }
        throw CellError.num
    }

    private static func newton(from guess: Double, lower: Double, upper: Double, _ f: (Double) -> Double) -> Double? {
        var x = guess
        for _ in 0..<100 {
            let value = f(x)
            guard value.isFinite else { return nil }
            if value == 0 { return x }
            let step = max(abs(x) * 1e-6, 1e-9)
            let slope = (f(x + step) - f(x - step)) / (2 * step)
            guard slope.isFinite, slope != 0 else { return nil }
            let next = x - value / slope
            guard next.isFinite, next > lower, next < upper else { return nil }
            if abs(next - x) <= 1e-13 * max(abs(next), 1e-3) { return next }
            x = next
        }
        return nil
    }

    /// 在一串试探点里找变号的相邻两点（离 guess 最近的那一段），再二分到底。
    private static func bisection(lower: Double, upper: Double, near guess: Double, _ f: (Double) -> Double) -> Double? {
        let probes = [-0.999, -0.99, -0.9, -0.5, -0.2, -0.1, -0.05, -0.01, 0, 0.001, 0.01, 0.05, 0.1, 0.2, 0.5,
                      1, 2, 5, 10, 100, 1000].filter { $0 > lower && $0 < upper }
        var best: (Double, Double)?
        for (a, b) in zip(probes, probes.dropFirst()) {
            let (fa, fb) = (f(a), f(b))
            guard fa.isFinite, fb.isFinite, fa.sign != fb.sign || fa == 0 || fb == 0 else { continue }
            if best == nil || abs((a + b) / 2 - guess) < abs((best!.0 + best!.1) / 2 - guess) {
                best = (a, b)
            }
        }
        guard var (low, high) = best else { return nil }
        var fLow = f(low)
        for _ in 0..<200 {
            let middle = (low + high) / 2
            let fMiddle = f(middle)
            if fMiddle == 0 || high - low < 1e-16 { return middle }
            if fMiddle.sign == fLow.sign {
                low = middle
                fLow = fMiddle
            } else {
                high = middle
            }
        }
        return (low + high) / 2
    }
}

/// 现金流折现：NPV、XNPV 直接用，IRR、XIRR 拿它当 f(r) 求根。
enum CashFlow {
    /// Σ vᵢ / (1+r)^(i + firstPeriod)。NPV 从第 1 期开始折现（firstPeriod 1）；IRR 的第一笔不折现（firstPeriod 0）。
    static func presentValue(rate: Double, values: [Double], firstPeriod: Double) -> Double {
        var total = 0.0
        for (index, value) in values.enumerated() {
            total += value / pow(1 + rate, Double(index) + firstPeriod)
        }
        return total
    }

    /// Σ vᵢ / (1+r)^((dᵢ − d₀)/365)：按实际日子折现（XNPV、XIRR）。
    static func datedPresentValue(rate: Double, values: [Double], days: [Double]) -> Double {
        guard let start = days.first else { return 0 }
        var total = 0.0
        for (value, day) in zip(values, days) {
            total += value / pow(1 + rate, (day - start) / 365)
        }
        return total
    }
}
