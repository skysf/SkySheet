import Foundation
import SkySheetCore
import SkySheetFiles

/// M1 的验收线（设计 5.6 节）：读 Fixtures/loan.xlsx、整本重算，124 个公式逐个和腾讯文档存的缓存值比。
///
/// 容差分两档：普通公式 1e-13（缓存值只存 15 位有效数字，我们用 Decimal 算得更准，差在第 15 位以后）；
/// 用到 RATE 的放宽到 1e-9：腾讯文档的 RATE 只迭代到大约 1e-10，和精确解最多差 6.5e-11（J10，2026-10-08 实测）。
@MainActor
func goldenLoanChecks() {
    guard let workbook = loadLoanFixture() else { return }

    group("golden: loan.xlsx reads like Tencent Docs shows it") {
        checkEqual(workbook.sheets.map(\.name), ["Loan"], "sheets")
        let sheet = workbook.sheets[0]
        func value(_ a1: String) -> CellValue? { sheet.cells[CellAddress(a1: a1)!]?.value }
        checkEqual(value("A1"), .text("贷款类型"), "A1")
        checkEqual(value("B3"), num("489000"), "B3")
        checkEqual(value("Q1"), num("36"), "Q1")
        checkEqual(value("O4"), .text("每月20日，到期2053年2月15日"), "O4 without the bank card note")
        checkEqual(sheet.cells[CellAddress(a1: "J5")!]?.formula?.source, "RATE(C5,-F5,B5)*12", "J5 formula")
        checkEqual(sheet.frozen, FrozenPanes(rows: 1, columns: 1), "frozen first row and column")
        checkEqual(sheet.columns.first { $0.first == 13 }?.width, 60, "column N width")
        checkEqual(sheet.tabColor, "FFFFFFFF", "tab color")
        let formulas = sheet.cells.entries(in: CellRange(a1: "A1:AG212")!).filter { $0.value.formula != nil }
        checkEqual(formulas.count, 124, "formula cells")
    }

    group("golden: recalculated values match Tencent Docs") {
        var recalculated = workbook
        let report = Recalculator.recalculate(&recalculated, options: RecalcOptions(today: checkToday))
        checkEqual(report.calculated, 124, "all formulas calculated")
        checkEqual(report.notRecalculated.count, 0, "nothing left uncalculated: \(report.notRecalculated)")
        checkEqual(report.circular.count, 0, "no cycles")

        var worst = (plain: 0.0, plainAt: "", rate: 0.0, rateAt: "")
        recalculated.sheets[0].cells.forEach { address, cell in
            guard let formula = cell.formula, let cached = formula.cachedValue else { return }
            guard case .number(let expected) = cached, case .number(let actual) = cell.value else {
                checkEqual(cell.value, cached, "\(address.a1) =\(formula.source)")
                return
            }
            let error = DecimalMath.double(abs(actual - expected)) / max(abs(DecimalMath.double(expected)), 1e-300)
            let iterative = formula.source.uppercased().contains("RATE(")
            check(error <= (iterative ? 1e-9 : 1e-13),
                  "\(address.a1) =\(formula.source): got \(actual), Tencent Docs \(expected), relative error \(error)")
            if iterative, error > worst.rate { worst.rate = error; worst.rateAt = address.a1 }
            if !iterative, error > worst.plain { worst.plain = error; worst.plainAt = address.a1 }
        }
        print("golden: worst relative error \(worst.plain) at \(worst.plainAt) (plain), \(worst.rate) at \(worst.rateAt) (RATE)")
    }

    group("golden: display text") {
        let sheet = workbook.sheets[0]
        let expected = ["G2": "0.1786%", "I2": "2.14%", "J5": "3.756%", "K2": "¥3,053.92 ", "D3": "1358.33",
                        "E3": "1214.010", "E5": "82.50 ", "B10": "¥8,673.94 ", "B3": "489000", "A2": "工行装修贷"]
        for (a1, text) in expected.sorted(by: { $0.key < $1.key }) {
            guard let cell = sheet.cells[CellAddress(a1: a1)!] else {
                fail("\(a1) missing")
                continue
            }
            let code = workbook.styles.formatCode(forStyle: cell.styleIndex)
            checkEqual(ValueFormatter.format(cell.value, code: code).text, text, "\(a1) with \(code)")
        }
    }
}

@MainActor
private func loadLoanFixture() -> Workbook? {
    do {
        return try XLSXReader.read(contentsOf: fixtureURL("loan.xlsx"))
    } catch {
        group("golden: loan.xlsx") { fail("could not read the fixture: \(error)") }
        return nil
    }
}
