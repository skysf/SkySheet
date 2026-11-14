import Foundation
import Synchronization

public struct RecalcOptions: Sendable {
    /// TODAY() 用哪一天。nil 是本机时区的今天；自检里固定成某一天。
    public var today: CivilDate?
    /// 上一次重算排好的计划：公式没变就接着用（RecalcCache）。不给就每次从头排。
    public var cache: RecalcCache?

    public init(today: CivilDate? = nil, cache: RecalcCache? = nil) {
        self.today = today
        self.cache = cache
    }
}

/// 两次重算之间留着的计划（2026-11-14，设计 5.5 节）。
///
/// 改一格的值（最常见的编辑）时，公式一个没变，计算顺序也就不变；原来每次都把所有公式从头解析、找依赖、排顺序，
/// 一万行的还款表（5 万个公式）光这一步就占了重算的七成多。现在比一比工作簿里的公式（位置、原文、sheet 名），
/// 一样就直接用上一次的计划，只把值重新算一遍。结果和从头排一模一样：计划只由这几样定。
/// 一个窗口一份（SheetSession 带着），读文件时那一次重算也用它，打开后第一次编辑就不用再排。
public final class RecalcCache: Sendable {
    private let state = Mutex<(layout: FormulaLayout, plan: RecalcPlan)?>(nil)
    private let builds = Mutex(0)

    public init() {}

    /// 一共从头排过几次计划（自检数它：只改值的编辑不该再排）。
    var planBuilds: Int { builds.withLock { $0 } }

    /// 这个工作簿的计划：公式和上一次一样就用上一次的，否则排一份新的记下来。
    func plan(for workbook: Workbook, layout: FormulaLayout) -> RecalcPlan {
        if let known = state.withLock({ $0 }), known.layout == layout { return known.plan }
        let plan = RecalcPlan(layout: layout, workbook: workbook)
        state.withLock { $0 = (layout, plan) }
        builds.withLock { $0 += 1 }
        return plan
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
        let layout = FormulaLayout(workbook)
        let plan = options.cache?.plan(for: workbook, layout: layout) ?? RecalcPlan(layout: layout, workbook: workbook)
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
