import Foundation

public struct RecalcOptions: Sendable {
    /// TODAY() 用哪一天。nil 是本机时区的今天；自检里固定成某一天。
    public var today: CivilDate?

    public init(today: CivilDate? = nil) {
        self.today = today
    }
}

public struct RecalcReport: Sendable {
    /// 算了几个公式。
    public var calculated = 0
    /// 算不了的公式和原因（显示的是文件里的缓存值）。
    public var notRecalculated: [FormulaLocation: String] = [:]
    public var circular: Set<FormulaLocation> = []
}

/// 整本重算（设计 5.5 节）。第一版每次都全算：几千行、几百个公式是毫秒级，慢了再做增量。
public enum Recalculator {
    @discardableResult
    public static func recalculate(_ workbook: inout Workbook, options: RecalcOptions = RecalcOptions()) -> RecalcReport {
        let plan = RecalcPlan(workbook: workbook)
        let today = options.today ?? CivilDate.today()
        let state = RecalcState(workbook: workbook, todaySerial: DateSerial.serial(from: today, system: workbook.dateSystem))

        for location in plan.unsupported.keys {
            let formula = workbook.sheets[location.sheet].cells[location.address]?.formula
            state.values[location] = formula?.cachedValue ?? .error(.name)
        }
        for location in plan.circular {
            state.values[location] = .error(.circular)
        }
        for location in plan.order where !plan.circular.contains(location) {
            guard let node = plan.parsed[location] else { continue }
            let context = RecalcContext(state: state, currentSheet: location.sheet, currentCell: location.address)
            let evaluator = Evaluator(context: context)
            let result = evaluator.scalar(evaluator.evaluate(node))
            // =A1 引用一个空格子显示 0，和 Excel 一样。
            state.values[location] = result == .empty ? .number(0) : result
        }

        var report = RecalcReport()
        for (location, value) in state.values {
            guard var cell = workbook.sheets[location.sheet].cells[location.address], var formula = cell.formula else { continue }
            if let reason = plan.unsupported[location] {
                formula.status = .notRecalculated(reason)
                report.notRecalculated[location] = reason
            } else {
                formula.status = .calculated
                report.calculated += 1
            }
            cell.value = value
            cell.formula = formula
            workbook.sheets[location.sheet].cells[location.address] = cell
        }
        report.circular = plan.circular
        return report
    }
}

/// 一次重算里大家共用的东西：工作簿（只读）和已经算好的公式值。
final class RecalcState {
    let workbook: Workbook
    let todaySerial: Int
    var values: [FormulaLocation: CellValue] = [:]
    /// 每张 sheet 用到的范围：一次重算里只算一次（查找函数裁整列引用时要用）。
    var usedRanges: [Int: CellRange?] = [:]

    init(workbook: Workbook, todaySerial: Int) {
        self.workbook = workbook
        self.todaySerial = todaySerial
    }
}

/// 算某一个公式时的上下文。公式格子读算好的值，别的格子读字面值。
struct RecalcContext: EvaluationContext {
    let state: RecalcState
    let currentSheet: Int
    let currentCell: CellAddress

    var dateSystem: DateSystem { state.workbook.dateSystem }
    var todaySerial: Int { state.todaySerial }

    func sheetIndex(named name: String) -> Int? {
        state.workbook.sheetIndex(named: name)
    }

    func value(sheet: Int, at address: CellAddress) -> CellValue {
        if let computed = state.values[FormulaLocation(sheet: sheet, address: address)] { return computed }
        guard state.workbook.sheets.indices.contains(sheet) else { return .error(.ref) }
        return state.workbook.sheets[sheet].cells[address]?.value ?? .empty
    }

    func entries(in area: Area) -> [(address: CellAddress, value: CellValue)] {
        guard state.workbook.sheets.indices.contains(area.sheet) else { return [] }
        return state.workbook.sheets[area.sheet].cells.entries(in: area.range).compactMap { address, cell in
            let value = cell.formula == nil
                ? cell.value
                : state.values[FormulaLocation(sheet: area.sheet, address: address)] ?? cell.value
            return value == .empty ? nil : (address, value)
        }
    }

    func usedRange(sheet: Int) -> CellRange? {
        guard state.workbook.sheets.indices.contains(sheet) else { return nil }
        if let cached = state.usedRanges[sheet] { return cached }
        let range = state.workbook.sheets[sheet].cells.usedRange
        state.usedRanges[sheet] = .some(range)
        return range
    }
}
