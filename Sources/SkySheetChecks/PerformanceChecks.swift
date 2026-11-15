import Foundation
import SkySheetCore

/// 设计 5.5 节：第一版每次整本重算，「M1 用一万行的合成表量一次，慢了再做增量依赖图」。
/// 一张 10,000 期的等额本息还款计划表：每行期初余额引用上一行的期末余额，依赖链一万层深，一共 5 万个公式。
/// 时间上限放得很宽（自检是 debug 构建，CI 的机器也慢），只防「变成平方级」那种退化；实际耗时打印出来看。
@MainActor
func performanceChecks() {
    group("performance: 10,000-row repayment schedule") {
        // 和测速模式用同一张合成表（SyntheticWorkbook.formulas，每期利率为什么取 0.01% 也写在那里）。
        var workbook = SyntheticWorkbook.formulas(periods: 10_000)
        workbook.sheets.removeLast()   // 换 sheet 用的小表，这里用不着
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
