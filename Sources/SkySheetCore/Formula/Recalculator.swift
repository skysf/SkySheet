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
    /// 上一次的计划，和排它时 sheet 的顺序（编号）、名字。
    private let state = Mutex<(sheetIDs: [Int], sheetNames: [String], plan: RecalcPlan)?>(nil)
    /// 每张表（按编号）上一次看到的格子和里面的公式：下一次只看改过的行（SparseGrid.rowsDiffering），
    /// 十万行的表改一格不用再把两百万个格子走一遍找公式。
    private let sheets = Mutex<[Int: (cells: SparseGrid<Cell>, formulas: FormulaLayout.SheetFormulas)]>([:])
    private let builds = Mutex(0)
    private let scans = Mutex(0)
    private let rescans = Mutex(0)

    public init() {}

    /// 一共从头排过几次计划（自检数它：只改值的编辑不该再排）。
    var planBuilds: Int { builds.withLock { $0 } }
    /// 一共整张表从头找过几次公式（自检数它：编辑以后只看改过的行）。
    var fullScans: Int { scans.withLock { $0 } }
    /// 一共重新看过几行（自检数它：改一格只看那一行）。
    var rowsRescanned: Int { rescans.withLock { $0 } }

    /// 算完、值写回去以后的格子记下来：下一次编辑只和它比。要是记的是写回之前的，公式多的表每个公式格子的值都变了，
    /// 下一次就成了每一行都「改过」（2026-11-14 实测，一万行的还款表改一格从约 95 毫秒退到 150）。写回只改值和状态，
    /// 公式本身（原文、数组范围）没变，记下的公式接着用。
    func noteCalculated(_ workbook: Workbook) {
        sheets.withLock { known in
            for sheet in workbook.sheets {
                guard let previous = known[sheet.id] else { continue }
                known[sheet.id] = (sheet.cells, previous.formulas)
            }
        }
    }

    /// 这个工作簿的计划。上一次见过的表只看改过的行：改过的行里公式（原文、数组范围）都没变、sheet 的顺序和名字也没变，
    /// 就是上一次的计划（计划只由这几样定），连整本的公式表都不用拼、不用比；否则拼出整本的公式（FormulaLayout）重排。
    func plan(for workbook: Workbook) -> RecalcPlan {
        let known = sheets.withLock { $0 }
        var next: [Int: (cells: SparseGrid<Cell>, formulas: FormulaLayout.SheetFormulas)] = [:]
        var perSheet: [FormulaLayout.SheetFormulas] = []
        var formulasChanged = known.count != workbook.sheets.count
        for sheet in workbook.sheets {
            var formulas: FormulaLayout.SheetFormulas
            if let previous = known[sheet.id] {
                formulas = previous.formulas
                // 不共用存储的行都重看一遍、按标量比公式原文（rowsNotShared、FormulaLayout.Entry）：只换了写法的公式
                // （é 和 e + U+0301）按 == 看不出来，计划就会接着用旧的。改一格时只有那一行不共用。
                let changed = sheet.cells.rowsNotShared(with: previous.cells)
                for row in changed {
                    let now = FormulaLayout.formulas(inRow: row, of: sheet.cells)
                    if now != formulas[row] {
                        formulas[row] = now
                        formulasChanged = true
                    }
                }
                rescans.withLock { $0 += changed.count }
            } else {
                formulas = FormulaLayout.formulas(in: sheet.cells)
                formulasChanged = true
                scans.withLock { $0 += 1 }
            }
            next[sheet.id] = (sheet.cells, formulas)
            perSheet.append(formulas)
        }
        sheets.withLock { $0 = next }
        let ids = workbook.sheets.map(\.id)
        let names = workbook.sheets.map(\.name)
        if !formulasChanged, let previous = state.withLock({ $0 }), previous.sheetIDs == ids, previous.sheetNames == names {
            return previous.plan
        }
        let plan = RecalcPlan(layout: FormulaLayout(workbook, sheets: perSheet), workbook: workbook)
        state.withLock { $0 = (ids, names, plan) }
        builds.withLock { $0 += 1 }
        return plan
    }

    /// 整本的公式（自检拿它和从头找的对照）。
    func layout(for workbook: Workbook) -> FormulaLayout {
        let known = sheets.withLock { $0 }
        return FormulaLayout(workbook, sheets: workbook.sheets.map { known[$0.id]?.formulas ?? FormulaLayout.formulas(in: $0.cells) })
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
        let plan = options.cache?.plan(for: workbook) ?? RecalcPlan(layout: FormulaLayout(workbook), workbook: workbook)
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
        options.cache?.noteCalculated(workbook)
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
