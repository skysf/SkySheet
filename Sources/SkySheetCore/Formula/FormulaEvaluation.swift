import Foundation

/// 算一个公式、不写进任何格子（设计 9.2 节 evaluate：「贷 100 万、30 年、3.1%，月供多少」）。
/// 工作簿要是已经重算过的：引用的格子直接读它们现在的值，公式格子读算好的结果，不再整本重算。
public enum FormulaEvaluation {
    public enum Outcome: Equatable, Sendable {
        case value(CellValue)
        /// 公式写错了，或者用了我们还算不了的东西（原因写给 AI 看，英文）。
        case unsupported(String)
    }

    public static func evaluate(_ formula: String, in workbook: Workbook, sheet: Int,
                                options: RecalcOptions = RecalcOptions()) -> Outcome {
        let source = formula.hasPrefix("=") ? String(formula.dropFirst()) : formula
        let node: FormulaNode
        do {
            node = try FormulaParser.parse(source)
        } catch {
            return .unsupported("could not read the formula (\(error))")
        }
        if let reason = RecalcPlan.unsupportedReason(node, workbook: workbook) { return .unsupported(reason) }
        let today = options.today ?? CivilDate.today()
        let state = RecalcState(workbook: workbook, todaySerial: DateSerial.serial(from: today, system: workbook.dateSystem))
        // 放在表格最右下角那一格算：相对引用、ROW() 这类从这一格算起，不会碰到真的数据。
        let corner = CellAddress(row: CellAddress.maxRows - 1, column: CellAddress.maxColumns - 1)
        let evaluator = Evaluator(context: RecalcContext(state: state, currentSheet: sheet, currentCell: corner))
        let result = evaluator.scalar(evaluator.evaluate(node))
        // =A1 引用一个空格子显示 0，和重算时一样。
        return .value(result == .empty ? .number(0) : result)
    }
}
