import Foundation
@testable import SkySheetCore
@testable import SkySheetDisplay

/// 大表格不卡（2026-11-14，设计 8.2 节「性能」）。两类检查：
/// - 快的写法和原来的写法结果一样（逐条对照，含边角）；
/// - 数得出来的量：画一屏只看这一屏的合并单元格、只改值的编辑不重排计划、拖边线时不重排没变的那个方向……
///   CI 的机器快慢不定，尽量不用时间判断；用时间的几处上限放得很宽，只防「变成整张表走一遍」那种退化。
/// 表格视图本身（局部重画）在 App 里，自检够不着，由测速模式的 verify 核对（docs/testing/m5-performance.md）。
@MainActor
func largeSheetChecks() {
    group("large sheets: parsing fast paths match the original rules") {
        let addresses = ["A1", "B12", "$B$12", "b12", "XFD1048576", "XFE1", "AAAA1", "A0", "A1048577", "A01", "A$1", "$$A1",
                         "A1B", "1A", "", "$", "A", "12", "A-1", "Ａ1", "A１", " A1", "A1 ", "ZZ99", "ab100", "A0000000000000000001",
                         "A99999999999999999999999", "é1"]
        for text in addresses {
            checkEqual(CellAddress(a1: text), CellAddress(slowA1: text), "address \(text)")
        }
        var random = SeededRandom(seed: 7)
        let alphabet = Array("AZaz019$ -.%e+")
        for _ in 0..<2000 {
            let text = String((0..<(1 + random.next(6))).map { _ in alphabet[random.next(alphabet.count)] })
            checkEqual(CellAddress(a1: text), CellAddress(slowA1: text), "address \(text)")
        }
        let numbers = ["0", "12", "-1.5", "+3", "3e-2", "1E+5", ".5", "5.", "12%", "-0.25%", "%", "-", "+", ".", "1,234",
                       " 12", "12 ", "\t7", "1 2", "0001", "1e", "1e+", "١٢", "12\n", "", "99999999999999999999999999999999999999",
                       "0.000000000000000000000000000001", "123456789.123456789", "-0", "1.2.3", "e5", "5e5e5"]
        for text in numbers {
            checkEqual(DecimalMath.parse(text), DecimalMath.parseScalars(text), "number \(text)")
        }
        let digits = Array("0123456789.-+eE% ")
        for _ in 0..<3000 {
            let text = String((0..<(1 + random.next(9))).map { _ in digits[random.next(digits.count)] })
            checkEqual(DecimalMath.parse(text), DecimalMath.parseScalars(text), "number \(text)")
        }
    }

    group("large sheets: exact sums match adding one by one") {
        var random = SeededRandom(seed: 11)
        func sequential(_ values: [Decimal]) -> Decimal {
            var total: Decimal = 0
            for value in values { total += value }
            return total
        }
        func fast(_ values: [Decimal]) -> (Decimal, Bool) {
            var sum = DecimalSum()
            for value in values { sum.add(value) }
            return (sum.value, sum.needsFallback)
        }
        var fastCount = 0
        for round in 0..<300 {
            // 一半只用表里常见的数（走快速加法），一半混进要退回去的（38 位有效数字的、特别大的、小数位太多的）。
            let kinds = round % 2 == 0 ? [0, 4, 5] : [0, 1, 2, 3, 4, 5]
            let values: [Decimal] = (0..<(1 + random.next(200))).map { _ in
                switch kinds[random.next(kinds.count)] {
                case 0: Decimal(random.next(1_000_000)) / 100 * (random.next(2) == 0 ? 1 : -1)
                case 1: Decimal(random.next(10)) / Decimal(3)                                  // 38 位有效数字：要退回去
                case 2: Decimal(sign: .plus, exponent: random.next(30), significand: Decimal(random.next(999) + 1))
                case 3: Decimal(string: "0.\(String(repeating: "0", count: random.next(20)))1")!
                case 4: Decimal(random.next(100_000_000))
                default: Decimal(random.next(1000)) / 1000
                }
            }
            let (value, fellBack) = fast(values)
            if !fellBack {
                fastCount += 1
                let expected = sequential(values)
                checkEqual(value, expected, "sum \(round)")
                for code in ["General", "#,##0.00", "0.00%", "\"¥\"#,##0.00_);[Red](\"¥\"#,##0.00)"] {
                    checkEqual(ValueFormatter.format(.number(value), code: code).text,
                               ValueFormatter.format(.number(expected), code: code).text, "sum \(round) shown as \(code)")
                }
                let count = Decimal(values.count)
                checkEqual(ValueFormatter.format(.number(value / count), code: "General").text,
                           ValueFormatter.format(.number(expected / count), code: "General").text, "average \(round)")
            }
        }
        check(fastCount >= 150, "sums of ordinary numbers stay on the fast path (\(fastCount) of 300)")

        // 状态栏的合计：和原来一个一个加的写法对照（有要退回去的数、没有的都试）。
        var sheet = SyntheticWorkbook.data(rows: 300).sheets[0]
        sheet.cells[5, 3] = Cell(value: .number(Decimal(1) / Decimal(3)))
        for range in [CellRange(a1: "A1:T301")!, CellRange(a1: "D2:H40")!, CellRange(a1: "D7:D7")!, CellRange(a1: "Z1:Z9")!,
                      CellRange.columns(3...5)] {
            let summary = SelectionSummary(cells: sheet.cells, range: range)
            var count = 0, numbers = 0
            var total: Decimal = 0
            for (_, cell) in sheet.cells.entries(in: range) where cell.value != .empty {
                count += 1
                if let number = cell.value.number {
                    numbers += 1
                    total += number
                }
            }
            checkEqual(summary.count, count, "count in \(range.label)")
            checkEqual(summary.numericCount, numbers, "numbers in \(range.label)")
            checkEqual(summary.sum, total, "sum in \(range.label)")
        }
    }

    group("large sheets: rows, merges and geometry") {
        // 一行里一段的格子：和整行排序再筛一样。
        var grid = SparseGrid<Int>()
        var random = SeededRandom(seed: 3)
        for _ in 0..<3000 { grid[random.next(40), random.next(300)] = random.next(100) }
        for row in 0..<40 {
            for columns in [0..<0, 0..<5, 3..<17, 0..<300, 250..<400, 100..<101] {
                let expected = grid.row(row).filter { columns.contains($0.column) }
                let actual = grid.entries(inRow: row, columns: columns)
                check(actual.map(\.column) == expected.map(\.column) && actual.map(\.value) == expected.map(\.value),
                      "row \(row) columns \(columns)")
            }
        }
        var unordered: [CellAddress: Int] = [:]
        grid.forEachUnordered { address, value in unordered[address] = value }
        var ordered: [CellAddress: Int] = [:]
        grid.forEach { address, value in ordered[address] = value }
        checkEqual(unordered, ordered, "unordered walk visits every cell once")

        // 合并单元格查找表：和从头找一样；画一屏只看这一屏附近的。
        let styled = SyntheticWorkbook.styles(blocks: 500).sheets[0]
        let index = MergeIndex(styled.merges)
        for _ in 0..<400 {
            let address = CellAddress(row: random.next(5100), column: random.next(30))
            checkEqual(index.merge(containing: address), styled.merges.first { $0.contains(address) }, "merge at \(address)")
        }
        let screen = index.merges(touchingRows: 1200...1240)
        checkEqual(screen, styled.merges.filter { $0.start.row <= 1240 && $0.end.row >= 1200 }, "merges on one screen")
        check(styled.merges.count == 6500 && screen.count < 80, "one screen looks at \(screen.count) of 6,500 merges")
        let started = Date()
        for row in stride(from: 0, to: 5000, by: 5) { _ = index.merge(containing: CellAddress(row: row, column: 1)) }
        check(Date().timeIntervalSince(started) < 2, "1,000 lookups among 6,500 merges")

        // 几何：上一份能接着用的方向接着用，结果和从头算一样。
        var sheet = SyntheticWorkbook.data(rows: 2000).sheets[0]
        for row in stride(from: 0, to: 2000, by: 3) { sheet.rowFormats[row] = RowFormat(height: 21) }
        let first = SheetGeometry(sheet: sheet, baseFontSize: 11, digitWidth: 8.16, zoom: 1, usedRange: sheet.cells.usedRange,
                                  reusing: nil)
        var widened = sheet
        widened.setColumnWidth(30, columns: 2...2)
        let dragged = SheetGeometry(sheet: widened, baseFontSize: 11, digitWidth: 8.16, zoom: 1, usedRange: first.usedRange,
                                    reusing: first)
        check(dragged.reusedRows && !dragged.reusedColumns, "dragging a column keeps the row layout")
        var taller = sheet
        taller.setRowHeight(40, rows: 5...5)
        let draggedRow = SheetGeometry(sheet: taller, baseFontSize: 11, digitWidth: 8.16, zoom: 1, usedRange: first.usedRange,
                                       reusing: first)
        check(draggedRow.reusedColumns && !draggedRow.reusedRows, "dragging a row keeps the column layout")
        for (geometry, source) in [(dragged, widened), (draggedRow, taller)] {
            let fresh = SheetGeometry(sheet: source, baseFontSize: 11, digitWidth: 8.16, zoom: 1)
            check(fresh.rowCount == geometry.rowCount && fresh.columnCount == geometry.columnCount
                    && (0...60).allSatisfy { fresh.x(ofColumn: $0) == geometry.x(ofColumn: $0) }
                    && (0...2100).allSatisfy { fresh.y(ofRow: $0) == geometry.y(ofRow: $0) },
                  "reused geometry equals a fresh one")
        }
        let zoomed = SheetGeometry(sheet: sheet, baseFontSize: 11, digitWidth: 8.16, zoom: 1.5, usedRange: first.usedRange,
                                   reusing: first)
        check(!zoomed.reusedRows && !zoomed.reusedColumns, "zooming lays both directions out again")
    }

    group("large sheets: editing a value reuses the recalculation plan") {
        var workbook = SyntheticWorkbook.formulas(periods: 400)
        let cache = RecalcCache()
        Recalculator.recalculate(&workbook, options: RecalcOptions(today: checkToday, cache: cache))
        checkEqual(cache.planBuilds, 1, "first recalculation builds the plan")
        let rate = CellAddress(a1: "H1")!
        for step in 1...5 {
            workbook.sheets[0].cells[rate] = Cell(value: .number(Decimal(step) / 10000))
            var fresh = workbook
            Recalculator.recalculate(&workbook, options: RecalcOptions(today: checkToday, cache: cache))
            Recalculator.recalculate(&fresh, options: RecalcOptions(today: checkToday))
            check(workbook == fresh, "value edit \(step): same results as recalculating from scratch")
        }
        checkEqual(cache.planBuilds, 1, "value edits keep the plan")
        workbook.sheets[0].cells[CellAddress(a1: "D7")!] = Cell(formula: CellFormula(source: "$H$2*2"))
        var fresh = workbook
        Recalculator.recalculate(&workbook, options: RecalcOptions(today: checkToday, cache: cache))
        Recalculator.recalculate(&fresh, options: RecalcOptions(today: checkToday))
        check(workbook == fresh, "formula edit: same results as recalculating from scratch")
        checkEqual(cache.planBuilds, 2, "a changed formula builds a new plan")
        workbook.sheets[0].name = "Plan"
        Recalculator.recalculate(&workbook, options: RecalcOptions(today: checkToday, cache: cache))
        checkEqual(cache.planBuilds, 3, "renaming a sheet builds a new plan (references go by name)")
    }

    group("large sheets: whole-sheet passes stay linear") {
        // 5,000 行 × 20 列（10 万格）：全选的合计、找公式各走一遍。debug 构建里零点几秒；上限放得很宽，
        // 只防退化成「每格再把整张表走一遍」。
        let workbook = SyntheticWorkbook.data(rows: 5000)
        let cells = workbook.sheets[0].cells
        var started = Date()
        let summary = SelectionSummary(cells: cells, range: CellRange(a1: "A1:T5001")!)
        let summarySeconds = Date().timeIntervalSince(started)
        checkEqual(summary.count, 100_020, "every cell counted")
        started = Date()
        let layout = FormulaLayout(workbook)
        let layoutSeconds = Date().timeIntervalSince(started)
        checkEqual(layout.formulas.count, 0, "no formulas in plain data")
        print(String(format: "large sheets: total of 100,020 cells in %.2f s, formula scan in %.2f s (debug build)",
                     summarySeconds, layoutSeconds))
        check(summarySeconds < 20 && layoutSeconds < 20, "whole-sheet passes took \(summarySeconds) s and \(layoutSeconds) s")
    }
}
