import Foundation

/// 一块解析好的区域：哪张 sheet（在工作簿里的位置）、哪些格子。
struct Area: Hashable, Sendable {
    let sheet: Int
    let range: CellRange
}

/// 求值时看得到的东西，由 Recalculator 提供（设计 5.5 节）。
protocol EvaluationContext {
    var currentSheet: Int { get }
    var currentCell: CellAddress { get }
    var dateSystem: DateSystem { get }
    var todaySerial: Int { get }
    func sheetIndex(named name: String) -> Int?
    func value(sheet: Int, at address: CellAddress) -> CellValue
    /// 区域里有值的格子（空格子不在里面），行优先。
    func entries(in area: Area) -> [(address: CellAddress, value: CellValue)]
    func usedRange(sheet: Int) -> CellRange?
}

/// 求值的中间结果：一个值、一块区域（交给函数自己决定怎么用），或者函数里空着的参数。
enum EvalValue {
    case value(CellValue)
    case area(Area)
    case missing
}

struct Evaluator {
    let context: any EvaluationContext

    func evaluate(_ node: FormulaNode) -> EvalValue {
        switch node {
        case .number(let value): return .value(.number(value))
        case .text(let value): return .value(.text(value))
        case .bool(let value): return .value(.bool(value))
        case .error(let error): return .value(.error(error))
        case .missing: return .missing
        case .reference(let reference):
            let sheet = reference.sheet.map { context.sheetIndex(named: $0) } ?? context.currentSheet
            guard let sheet else { return .value(.error(.ref)) }
            return .area(Area(sheet: sheet, range: reference.range))
        case .name: return .value(.error(.name))
        case .dynamicRange: return .value(.error(.value))
        case .negate(let operand): return .value(Operators.negate(scalar(operand)))
        case .unaryPlus(let operand): return evaluate(operand)
        case .percent(let operand): return .value(Operators.percent(scalar(operand)))
        case .binary(let op, let left, let right): return .value(Operators.apply(op, scalar(left), scalar(right)))
        case .call(let name, let arguments): return .value(call(name, arguments))
        }
    }

    func scalar(_ node: FormulaNode) -> CellValue {
        scalar(evaluate(node))
    }

    func scalar(_ value: EvalValue) -> CellValue {
        switch value {
        case .value(let value): value
        case .missing: .empty
        case .area(let area): intersect(area)
        }
    }

    /// 隐式交集：要一个值、给的却是区域时，取和公式同一行（单列区域）或同一列（单行区域）的那一格，对不上就是 #VALUE!。
    /// 老版 Excel 一直这么算，`=A1:A10*2` 写在第 3 行就是 A3*2。
    func intersect(_ area: Area) -> CellValue {
        let range = area.range
        let here = context.currentCell
        if range.rowCount == 1, range.columnCount == 1 {
            return context.value(sheet: area.sheet, at: range.start)
        }
        if range.columnCount == 1, (range.start.row...range.end.row).contains(here.row) {
            return context.value(sheet: area.sheet, at: CellAddress(row: here.row, column: range.start.column))
        }
        if range.rowCount == 1, (range.start.column...range.end.column).contains(here.column) {
            return context.value(sheet: area.sheet, at: CellAddress(row: range.start.row, column: here.column))
        }
        return .error(.value)
    }

    private func call(_ name: String, _ arguments: [FormulaNode]) -> CellValue {
        guard let spec = FunctionLibrary.spec(named: name) else { return .error(.name) }
        guard spec.arguments.contains(arguments.count) else { return .error(.value) }
        let values = FunctionArguments(values: arguments.map(evaluate), evaluator: self)
        do throws(CellError) {
            return try spec.evaluate(values)
        } catch {
            return .error(error)
        }
    }
}
