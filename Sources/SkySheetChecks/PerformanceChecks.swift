import Foundation
import SkySheetCore

/// 设计 5.5 节：第一版每次整本重算，「M1 用一万行的合成表量一次，慢了再做增量依赖图」。
/// 一张 10,000 期的等额本息还款计划表：每行期初余额引用上一行的期末余额，依赖链一万层深，一共 5 万个公式。
/// 时间上限放得很宽（自检是 debug 构建，CI 的机器也慢），只防「变成平方级」那种退化；实际耗时打印出来看。
@MainActor
func performanceChecks() {
    group("performance: 10,000-row repayment schedule") {
        // 每期利率取 0.01%。别用 0.25%：一万期的话 1.0025^10000 ≈ 7e10，PMT 在第 16 位上的舍入误差会被放大三十万亿倍，
        // 期末余额差出几块钱（2026-10-08 实测 -7.70）。那是这种长链本身的病态，Excel 一样；30 年房贷只放大 584 倍。
        var cells = ["H1": "0.0001", "H2": "=PMT(H1,10000,-1000000)"]
        for row in 1...10_000 {
            cells["A\(row)"] = "\(row)"
            cells["B\(row)"] = row == 1 ? "1000000" : "=F\(row - 1)"   // 期初余额 = 上一期的期末余额
            cells["C\(row)"] = "=B\(row)*$H$1"                         // 利息
            cells["D\(row)"] = "=$H$2"                                 // 每期还款
            cells["E\(row)"] = "=D\(row)-C\(row)"                      // 本金
            cells["F\(row)"] = "=B\(row)-E\(row)"                      // 期末余额
        }
        var workbook = Workbook(sheets: [makeSheet("Schedule", id: 1, cells)])
        let started = Date()
        let report = Recalculator.recalculate(&workbook, options: RecalcOptions(today: checkToday))
        let seconds = Date().timeIntervalSince(started)
        print(String(format: "performance: %d formulas recalculated in %.2f s (debug build)", report.calculated, seconds))

        checkEqual(report.calculated, 50_000, "formulas calculated")
        guard case .number(let balance)? = workbook.sheets[0].cells[CellAddress(a1: "F10000")!]?.value else {
            fail("no final balance")
            return
        }
        check(abs(DecimalMath.double(balance)) < 1e-6, "loan is paid off after the last period: \(balance)")
        check(seconds < 60, "recalculation took \(seconds) s")
    }
}
