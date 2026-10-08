import Foundation

/// 一个公式格子的位置：第几张 sheet、哪一格。
public struct FormulaLocation: Hashable, Comparable, Sendable {
    public var sheet: Int
    public var address: CellAddress

    public init(sheet: Int, address: CellAddress) {
        self.sheet = sheet
        self.address = address
    }

    public static func < (lhs: FormulaLocation, rhs: FormulaLocation) -> Bool {
        (lhs.sheet, lhs.address) < (rhs.sheet, rhs.address)
    }
}

/// 一次重算的准备（设计 5.5 节）：解析每个公式、挑出算不了的、找出公式之间的依赖、排好先后。
///
/// 排序不用递归：几百行的还款计划表每一行都引用上一行，递归深度就是行数，会把后台线程的栈撑爆。
/// 所以先用显式的栈排出顺序，再按顺序一个个算，每个格子算的时候它引用的公式都已经算好了。
struct RecalcPlan {
    private(set) var parsed: [FormulaLocation: FormulaNode] = [:]
    /// 算不了的公式和原因。它们显示文件里的缓存值（设计 5.3 节）。
    private(set) var unsupported: [FormulaLocation: String] = [:]
    private(set) var order: [FormulaLocation] = []
    private(set) var circular: Set<FormulaLocation> = []

    init(workbook: Workbook) {
        // 每张 sheet 上哪些格子有公式：sheet → 列 → 行（从小到大）。找依赖时按列二分查找。
        var formulaCells: [Int: [Int: [Int]]] = [:]
        var cache: [String: Result<FormulaNode, FormulaSyntaxError>] = [:]
        for (sheetIndex, sheet) in workbook.sheets.enumerated() {
            sheet.cells.forEach { address, cell in
                guard let formula = cell.formula else { return }
                let location = FormulaLocation(sheet: sheetIndex, address: address)
                formulaCells[sheetIndex, default: [:]][address.column, default: []].append(address.row)
                if formula.arrayRange != nil {
                    unsupported[location] = "array formulas are not supported yet"
                    return
                }
                let result = cache[formula.source] ?? Result { () throws(FormulaSyntaxError) -> FormulaNode in
                    try FormulaParser.parse(formula.source)
                }
                cache[formula.source] = result
                switch result {
                case .failure(let error):
                    unsupported[location] = "could not read the formula (\(error))"
                case .success(let node):
                    if let reason = Self.unsupportedReason(node, workbook: workbook) {
                        unsupported[location] = reason
                    } else {
                        parsed[location] = node
                    }
                }
            }
        }

        var dependencies: [FormulaLocation: [FormulaLocation]] = [:]
        for (location, node) in parsed {
            var found: [FormulaLocation] = []
            Self.forEachReference(in: node) { reference in
                guard let sheet = reference.sheet.map({ workbook.sheetIndex(named: $0) }) ?? location.sheet,
                      let columns = formulaCells[sheet] else { return }
                let range = reference.range
                for (column, rows) in columns where (range.start.column...range.end.column).contains(column) {
                    var index = rows.lowerBound(of: range.start.row)
                    while index < rows.count, rows[index] <= range.end.row {
                        found.append(FormulaLocation(sheet: sheet, address: CellAddress(row: rows[index], column: column)))
                        index += 1
                    }
                }
            }
            dependencies[location] = found
        }
        (order, circular) = Self.topologicalOrder(parsed.keys.sorted(), dependencies)
    }

    /// 为什么算不了；能算返回 nil。
    static func unsupportedReason(_ node: FormulaNode, workbook: Workbook) -> String? {
        switch node {
        case .call(let name, let arguments):
            guard let spec = FunctionLibrary.spec(named: name) else { return "function \(name) is not supported yet" }
            guard spec.arguments.contains(arguments.count) else {
                return "\(name) takes \(spec.arguments.lowerBound) to \(spec.arguments.upperBound) arguments, got \(arguments.count)"
            }
            return arguments.lazy.compactMap { unsupportedReason($0, workbook: workbook) }.first
        case .name(let name):
            return "defined names such as \(name) are not supported yet"
        case .dynamicRange:
            return "ranges built from functions (A1:INDEX(…)) are not supported yet"
        case .reference(let reference):
            if let sheet = reference.sheet, workbook.sheetIndex(named: sheet) == nil {
                return "sheet \(sheet) is not in this workbook"
            }
            return nil
        case .negate(let operand), .unaryPlus(let operand), .percent(let operand):
            return unsupportedReason(operand, workbook: workbook)
        case .binary(_, let left, let right):
            return unsupportedReason(left, workbook: workbook) ?? unsupportedReason(right, workbook: workbook)
        case .number, .text, .bool, .error, .missing:
            return nil
        }
    }

    static func forEachReference(in node: FormulaNode, _ body: (ReferenceToken) -> Void) {
        switch node {
        case .reference(let reference): body(reference)
        case .negate(let operand), .unaryPlus(let operand), .percent(let operand): forEachReference(in: operand, body)
        case .binary(_, let left, let right), .dynamicRange(let left, let right):
            forEachReference(in: left, body)
            forEachReference(in: right, body)
        case .call(_, let arguments): arguments.forEach { forEachReference(in: $0, body) }
        case .number, .text, .bool, .error, .missing, .name: break
        }
    }

    /// 深度优先的后序就是计算顺序。碰到还在栈上的格子就是循环引用：栈上从它到栈顶的都算在环里。
    private static func topologicalOrder(_ roots: [FormulaLocation],
                                         _ dependencies: [FormulaLocation: [FormulaLocation]])
        -> ([FormulaLocation], Set<FormulaLocation>) {
        enum Mark { case visiting, done }
        var marks: [FormulaLocation: Mark] = [:]
        var order: [FormulaLocation] = []
        var circular: Set<FormulaLocation> = []
        for root in roots where marks[root] == nil {
            var stack: [(location: FormulaLocation, next: Int)] = [(root, 0)]
            marks[root] = .visiting
            while let top = stack.last {
                let children = dependencies[top.location] ?? []
                guard top.next < children.count else {
                    marks[top.location] = .done
                    order.append(top.location)
                    stack.removeLast()
                    continue
                }
                stack[stack.count - 1].next += 1
                let child = children[top.next]
                switch marks[child] {
                case nil:
                    marks[child] = .visiting
                    stack.append((child, 0))
                case .visiting?:
                    if let start = stack.lastIndex(where: { $0.location == child }) {
                        stack[start...].forEach { circular.insert($0.location) }
                    }
                case .done?:
                    break
                }
            }
        }
        return (order, circular)
    }
}

extension [Int] {
    /// 第一个 ≥ value 的位置（数组从小到大排好）。
    func lowerBound(of value: Int) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            if self[middle] < value { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
