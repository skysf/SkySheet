import Foundation
@testable import SkySheetCore
@testable import SkySheetDisplay

/// 状态栏合计和 SUM 一模一样、和走的先后无关（2026-11-15）。
///
/// Codex 审 PR #10 时指出：A1:A4 = 9×10¹⁹、A5 = 10⁻¹⁸、A6:A9 = −9×10¹⁹。SUM 按行优先用 Decimal 一个一个加，到 A5 时
/// 和是 3.6×10²⁰，再加 10⁻¹⁸ 要 39 位有效数字，Decimal 只有 38 位，小量被舍掉，最后是 0（本机实跑确认）。状态栏原来先
/// 不排序地走一遍、用整数精确地加：走的先后要是正负交替，每一步的和都没出界，得到精确的 10⁻¹⁸；先碰到两个正数就出界、
/// 退回按行加，得到 0。走的先后由字典定（每次启动的哈希种子都不一样），同一批格子每次的合计可能不同，也可能和 SUM 不同。
@MainActor
func selectionSumChecks() {
    let big = DecimalMath.parse("90000000000000000000")!
    let tiny = DecimalMath.parse("0.000000000000000001")!

    group("status bar sum: the fast path's decision doesn't depend on the order") {
        let rowMajor = [big, big, big, big, tiny, -big, -big, -big, -big]
        let alternating = [big, -big, big, -big, tiny, big, -big, big, -big]
        var sequential: Decimal = 0
        for value in rowMajor { sequential += value }
        checkEqual(sequential, 0, "Foundation drops the tiny one in row-major order (39 significant digits)")
        for (name, values) in [("row-major", rowMajor), ("alternating", alternating)] {
            var sum = DecimalSum()
            for value in values { sum.add(value) }
            check(sum.needsFallback || sum.value == sequential, "\(name): the fast path may only answer when it equals SUM")
        }
    }

    group("status bar sum: equals SUM over the same cells") {
        // Codex 的例子放在不同的行上：字典里走的先后跟着变。
        let values = [big, big, big, big, tiny, -big, -big, -big, -big]
        for offset in 0..<64 {
            var cells: [String: String] = [:]
            for (index, value) in values.enumerated() { cells["A\(offset + index + 1)"] = "\(value)" }
            compareWithSUM(cells, "A\(offset + 1):A\(offset + 9)", "Codex's example at row \(offset + 1)")
        }
        // 随机的表：数量级混着来（大到 10¹⁹、小到 10⁻¹⁸、公式算出来那种 30 多位的），正负都有，框随机。
        var random = SeededRandom(seed: 15_11_2026)
        let magnitudes = ["90000000000000000000", "12345678901234567890", "1234567.25", "0.5", "0.000000000000000001",
                          "0.123456789012345678", "1.2345678901234567890123456789012345", "-3", "0"]
        for round in 0..<300 {
            var cells: [String: String] = [:]
            let rows = 1 + random.next(12), columns = 1 + random.next(4)
            for row in 1...rows {
                for column in 0..<columns where random.next(4) != 0 {
                    var text = magnitudes[random.next(magnitudes.count)]
                    if random.next(2) == 0, text != "0" { text = text.hasPrefix("-") ? String(text.dropFirst()) : "-" + text }
                    cells["\(["A", "B", "C", "D"][column])\(row)"] = text
                }
            }
            compareWithSUM(cells, "A1:\(["A", "B", "C", "D"][columns - 1])\(rows)", "round \(round)")
        }
    }
}

/// 同一批格子：状态栏的合计（SelectionSummary）和 SUM 算出来的数一样，写出来的每一位也一样。
@MainActor
private func compareWithSUM(_ cells: [String: String], _ range: String, _ label: String) {
    let sheet = makeSheet("Sheet1", id: 1, cells)
    guard let area = CellRange.parse(range) else { return fail("bad range \(range)") }
    let summary = SelectionSummary(cells: sheet.cells, range: area)
    guard case .number(let expected) = evaluate("SUM(\(range))", cells, at: "Z100") else {
        return fail("\(label): SUM didn't give a number")
    }
    check(summary.sum == expected && DecimalMath.plainString(summary.sum) == DecimalMath.plainString(expected),
          "\(label): status bar \(summary.sum), SUM \(expected), cells \(cells.sorted { $0.key < $1.key })")
}
