import Foundation
@testable import SkySheetCore
@testable import SkySheetDisplay

/// 按字符串做键的缓存（2026-11-15）：Swift 的 String 相等按「规范等价」算，é（U+00E9）和 e + U+0301 是同一个键；
/// 可公式切词按 Unicode 标量来，两种写法结果不同（e + U+0301 里的 U+0301 不是字母，`Cafe\u{301}!A1` 读不出来，
/// `Café!A1` 是一个引用）。字体量字也按标量：Verdana、Georgia 这类字体里两种写法宽度不同（本机实测）。
/// 缓存按 String 做键，先进去的那个就替后来的那个答了（Codex 审 PR #10 时指出解析缓存这一处）。
@MainActor
func exactTextChecks() {
    group("string keys: canonically equivalent sources are different formulas") {
        // 两种写法 Swift 认为相等：这正是坑在哪。
        check("Caf\u{E9}!A1" == "Cafe\u{301}!A1", "Swift's String equality is canonical")

        // 先读到读不出来的那个，后一个有效的公式不能跟着「读不出来」（反过来也一样）。
        let cafe = makeSheet("Caf\u{E9}", id: 2, ["A1": "5"])
        var first = Workbook(sheets: [makeSheet("Sheet1", id: 1, ["B1": "=Cafe\u{301}!A1"]), cafe])
        Recalculator.recalculate(&first, options: RecalcOptions(today: checkToday))
        checkEqual(first.sheets[0].cells[CellAddress(a1: "B1")!]?.value, .error(.name), "the decomposed one can't be read")
        var second = Workbook(sheets: [makeSheet("Sheet1", id: 1, ["C1": "=Caf\u{E9}!A1"]), cafe])
        Recalculator.recalculate(&second, options: RecalcOptions(today: checkToday))
        checkEqual(second.sheets[0].cells[CellAddress(a1: "C1")!]?.value, num("5"),
                   "a valid formula in another workbook doesn't pick up its look-alike's failure")

        let gruen = makeSheet("Gr\u{FC}n", id: 2, ["A1": "6"])
        var valid = Workbook(sheets: [makeSheet("Sheet1", id: 1, ["B1": "=Gr\u{FC}n!A1"]), gruen])
        Recalculator.recalculate(&valid, options: RecalcOptions(today: checkToday))
        checkEqual(valid.sheets[0].cells[CellAddress(a1: "B1")!]?.value, num("6"), "the precomposed one is a reference")
        var lookAlike = Workbook(sheets: [makeSheet("Sheet1", id: 1, ["C1": "=Gru\u{308}n!A1"]), gruen])
        Recalculator.recalculate(&lookAlike, options: RecalcOptions(today: checkToday))
        checkEqual(lookAlike.sheets[0].cells[CellAddress(a1: "C1")!]?.value, .error(.name),
                   "an unreadable formula doesn't pick up its look-alike's success")

        // 重算计划「公式没变」的判断也按标量比。
        check(FormulaLayout.Entry(source: "Caf\u{E9}!A1", arrayRange: nil)
              != FormulaLayout.Entry(source: "Cafe\u{301}!A1", arrayRange: nil), "layout entries compare by scalars")

        // 同一格的公式只换了写法（重新载入文件时会这样）：格子的 == 看不出来，接着用的计划也得重排。
        let cache = RecalcCache()
        let address = CellAddress(a1: "B1")!
        var reloaded = Workbook(sheets: [makeSheet("Sheet1", id: 1, ["B1": "=Cafe\u{301}!A2"]),
                                         makeSheet("Caf\u{E9}", id: 2, ["A2": "7"])])
        Recalculator.recalculate(&reloaded, options: RecalcOptions(today: checkToday, cache: cache))
        checkEqual(reloaded.sheets[0].cells[address]?.value, .error(.name), "before: the decomposed form can't be read")
        var cell = reloaded.sheets[0].cells[address]!
        cell.formula!.source = "Caf\u{E9}!A2"
        check(cell == reloaded.sheets[0].cells[address]!, "Swift's == can't tell the two cells apart")
        reloaded.sheets[0].cells[address] = cell
        Recalculator.recalculate(&reloaded, options: RecalcOptions(today: checkToday, cache: cache))
        checkEqual(reloaded.sheets[0].cells[address]?.value, num("7"), "after: the reused plan follows the new spelling")
    }

    group("string keys: cached display text follows the cell's own scalars") {
        // 同一格从一种写法换成另一种（比如重新载入了文件）：显示的文字要跟着换，不能接着用记下的那一种
        // （有的字体里两种写法画出来不一样）。
        let cache = DisplayContentCache()
        let address = CellAddress(row: 0, column: 0)
        let style = StyleResolver(workbook: Workbook(sheets: [Sheet(id: 1, name: "Sheet1")])).style(0)
        let precomposed = Cell(value: .text("Vi\u{1EC7}t"))
        let decomposed = Cell(value: .text("Vie\u{323}\u{302}t"))
        _ = cache.content(of: precomposed, at: address, style: style, dateSystem: .from1900)
        let shown = cache.content(of: decomposed, at: address, style: style, dateSystem: .from1900).text
        check(Array(shown.unicodeScalars) == Array("Vie\u{323}\u{302}t".unicodeScalars),
              "shows the decomposed text, got \(shown.unicodeScalars.map { String($0.value, radix: 16) })")
    }
}
