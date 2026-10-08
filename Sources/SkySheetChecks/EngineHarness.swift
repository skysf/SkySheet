import Foundation
import SkySheetCore

// MARK: - 在临时工作簿里算公式
//
// 格子用文字描述："=…" 是公式，像数字的是数字，TRUE / FALSE 是逻辑值，其余是文字（想要像数字的文字就加个前缀 '）。

/// 自检里固定的「今天」：TODAY() 的结果不随跑的日子变。
let checkToday = CivilDate(year: 2026, month: 10, day: 8)

func makeSheet(_ name: String, id: Int, _ cells: [String: String]) -> Sheet {
    var sheet = Sheet(id: id, name: name)
    for (a1, text) in cells {
        guard let address = CellAddress(a1: a1) else { fatalError("bad address \(a1)") }
        sheet.cells[address] = seedCell(text)
    }
    return sheet
}

func seedCell(_ text: String) -> Cell {
    if text.hasPrefix("=") {
        return Cell(formula: CellFormula(source: String(text.dropFirst())))
    }
    if text.hasPrefix("'") { return Cell(value: .text(String(text.dropFirst()))) }
    if let number = DecimalMath.parse(text) { return Cell(value: .number(number)) }
    switch text {
    case "TRUE": return Cell(value: .bool(true))
    case "FALSE": return Cell(value: .bool(false))
    case "": return Cell(value: .empty)
    default: return Cell(value: .text(text))
    }
}

/// 把公式放在 `at`（默认 Z100，离数据远一点），和 `cells` 一起放进 Sheet1 算一遍，返回它的值。
func evaluate(_ formula: String, _ cells: [String: String] = [:], at a1: String = "Z100",
              otherSheets: [String: [String: String]] = [:]) -> CellValue {
    var all = cells
    all[a1] = "=" + formula
    var workbook = Workbook(sheets: [makeSheet("Sheet1", id: 1, all)])
    for (index, (name, sheetCells)) in otherSheets.sorted(by: { $0.key < $1.key }).enumerated() {
        workbook.sheets.append(makeSheet(name, id: index + 2, sheetCells))
    }
    Recalculator.recalculate(&workbook, options: RecalcOptions(today: checkToday))
    return workbook.sheets[0].cells[CellAddress(a1: a1)!]?.value ?? .empty
}

/// 结果是一个数，并且和期望值的相对误差不超过 `tolerance`。
@MainActor
func checkNumber(_ value: CellValue, _ expected: Double, tolerance: Double = 1e-12, _ message: String,
                 file: StaticString = #fileID, line: UInt = #line) {
    guard case .number(let number) = value else {
        fail("\(message): got \(value), expected about \(expected)", file: file, line: line)
        return
    }
    let actual = DecimalMath.double(number)
    let error = abs(actual - expected) / max(abs(expected), 1e-300)
    check(error <= tolerance || actual == expected,
          "\(message): got \(actual), expected \(expected) (relative error \(error))", file: file, line: line)
}

/// 精确比较：数字按 Decimal 精确相等。
@MainActor
func checkValue(_ formula: String, _ cells: [String: String], _ expected: CellValue,
                file: StaticString = #fileID, line: UInt = #line) {
    checkEqual(evaluate(formula, cells), expected, "=\(formula)", file: file, line: line)
}

/// 不需要别的格子时。（带默认值的参数夹在中间，两个参数的调用会把期望值错当成格子，所以分成两个。）
@MainActor
func checkValue(_ formula: String, _ expected: CellValue, file: StaticString = #fileID, line: UInt = #line) {
    checkValue(formula, [:], expected, file: file, line: line)
}

func num(_ text: String) -> CellValue {
    .number(Decimal(string: text)!)
}
