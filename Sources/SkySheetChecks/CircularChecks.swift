import Foundation
@testable import SkySheetCore

/// 循环引用（2026-11-15，设计 5.5 节）：环上的每个公式都标「循环引用」，标哪些和走的先后无关。
/// 原来深度优先走到「还在栈上的格子」才把栈上那一段标上：A1 = SUM(B1:C1)、B1 = A1、C1 = IFERROR(B1,7)，先走 B1 时
/// A1、B1 标上了，走到 C1 时 B1 已经走完，C1 没标、显示 7；可它在环 A1 → C1 → B1 → A1 上（Codex 审 PR #10 时指出）。
@MainActor
func circularChecks() {
    group("circular references: every formula on a cycle is marked, whatever the order") {
        var workbook = Workbook(sheets: [makeSheet("Sheet1", id: 1, ["A1": "=SUM(B1:C1)", "B1": "=A1",
                                                                     "C1": "=IFERROR(B1,7)"])])
        let report = Recalculator.recalculate(&workbook, options: RecalcOptions(today: checkToday))
        checkEqual(report.circular, circularLocations(["A1", "B1", "C1"]), "Codex's example: all three are on the cycle")
        checkEqual(workbook.sheets[0].cells[CellAddress(a1: "C1")!]?.value, .error(.circular), "C1 is on the cycle, not 7")

        // 同一个图换着位置放、换着参数的先后写：深度优先走的先后跟着变，标的格子不能变。
        let places = ["A1", "B1", "C1"]
        for (x, y, z) in [(0, 1, 2), (0, 2, 1), (1, 0, 2), (1, 2, 0), (2, 0, 1), (2, 1, 0)] {
            for swapped in [false, true] {
                let (a, b, c) = (places[x], places[y], places[z])
                let sum = swapped ? "=SUM(\(c),\(b))" : "=SUM(\(b),\(c))"
                var workbook = Workbook(sheets: [makeSheet("Sheet1", id: 1, [a: sum, b: "=\(a)", c: "=IFERROR(\(b),7)"])])
                let report = Recalculator.recalculate(&workbook, options: RecalcOptions(today: checkToday))
                checkEqual(report.circular, circularLocations([a, b, c]), "cycle at \(a) \(b) \(c), swapped \(swapped)")
            }
        }
    }

    group("circular references: random graphs match a brute-force answer") {
        // 一行 8 格，随机写公式（引用单格、两格的范围、IFERROR 包一层），有的格子是数。标的必须正好是「从自己出发
        // 能走回自己」的那些公式（小图上直接搜）。
        var random = SeededRandom(seed: 2026_11_15)
        let columns = ["A", "B", "C", "D", "E", "F", "G", "H"]
        for round in 0..<400 {
            var cells: [String: String] = [:]
            var edges: [Int: Set<Int>] = [:]
            for index in columns.indices {
                guard random.next(5) != 0 else {
                    cells[columns[index] + "1"] = String(index + 1)
                    continue
                }
                var terms: [String] = []
                var targets: Set<Int> = []
                for _ in 0..<(1 + random.next(3)) {
                    let target = random.next(columns.count)
                    if random.next(3) == 0, target + 1 < columns.count {
                        terms.append("SUM(\(columns[target])1:\(columns[target + 1])1)")
                        targets.formUnion([target, target + 1])
                    } else {
                        terms.append(columns[target] + "1")
                        targets.insert(target)
                    }
                }
                let body = terms.joined(separator: "+")
                cells[columns[index] + "1"] = random.next(3) == 0 ? "=IFERROR(\(body),7)" : "=" + body
                edges[index] = targets
            }
            // 引用到的格子是数（不是公式）就没有边。
            let formulas = Set(edges.keys)
            var expected: Set<String> = []
            for start in formulas {
                var seen: Set<Int> = []
                var stack = Array(edges[start, default: []].intersection(formulas))
                while let next = stack.popLast() {
                    guard seen.insert(next).inserted else { continue }
                    stack.append(contentsOf: edges[next, default: []].intersection(formulas))
                }
                if seen.contains(start) { expected.insert(columns[start] + "1") }
            }
            var workbook = Workbook(sheets: [makeSheet("Sheet1", id: 1, cells)])
            let report = Recalculator.recalculate(&workbook, options: RecalcOptions(today: checkToday))
            checkEqual(report.circular, circularLocations(Array(expected)), "round \(round): \(cells.sorted { $0.key < $1.key })")
        }
    }

    group("circular references: ten thousand deep") {
        // 一万格连成一个环：不能爆栈，一万格都标上。
        var cells = ["A1": "=A10000+1"]
        for row in 2...10_000 { cells["A\(row)"] = "=A\(row - 1)+1" }
        var workbook = Workbook(sheets: [makeSheet("Sheet1", id: 1, cells)])
        let report = Recalculator.recalculate(&workbook, options: RecalcOptions(today: checkToday))
        checkEqual(report.circular.count, 10_000, "the whole ring")
        // 一万层深的链挂在一个小环下面：链上的不在环上，不标，值是从环传下来的错误。
        cells = ["B1": "=C1", "C1": "=B1"]
        cells["A1"] = "=B1+1"
        for row in 2...10_000 { cells["A\(row)"] = "=A\(row - 1)+1" }
        workbook = Workbook(sheets: [makeSheet("Sheet1", id: 1, cells)])
        let chained = Recalculator.recalculate(&workbook, options: RecalcOptions(today: checkToday))
        checkEqual(chained.circular, circularLocations(["B1", "C1"]), "only the small ring")
        checkEqual(workbook.sheets[0].cells[CellAddress(a1: "A10000")!]?.value, .error(.circular), "the chain carries the error")
    }
}

private func circularLocations(_ cells: [String]) -> Set<FormulaLocation> {
    Set(cells.map { FormulaLocation(sheet: 0, address: CellAddress(a1: $0)!) })
}
