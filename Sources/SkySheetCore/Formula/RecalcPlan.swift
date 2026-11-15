import Foundation
import Synchronization

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

/// 工作簿里的公式：每个公式格子的位置、原文、数组公式的范围，加上 sheet 名的顺序（公式按名字找 sheet）。
/// 重算的计划（RecalcPlan）只由它定：两次重算之间它没变（只改了值，这是最常见的编辑），上一次排好的计划整个接着用
/// （RecalcCache，2026-11-14）。收集时不按格子排序（顺序和计划无关）。
struct FormulaLayout: Equatable {
    struct Entry: Equatable {
        let source: String
        let arrayRange: CellRange?
    }

    /// 一张表里的公式，按行：行 → 列 → 公式。
    typealias SheetFormulas = [Int: [Int: Entry]]

    let sheetNames: [String]
    let formulas: [FormulaLocation: Entry]

    init(_ workbook: Workbook) {
        self.init(workbook, sheets: workbook.sheets.map { Self.formulas(in: $0.cells) })
    }

    /// `sheets` 是每张表（按位置）里的公式（`formulas(in:)` 的结果，或者 RecalcCache 只改了几行的那一份）。
    init(_ workbook: Workbook, sheets: [SheetFormulas]) {
        sheetNames = workbook.sheets.map(\.name)
        var formulas: [FormulaLocation: Entry] = [:]
        for (sheetIndex, rows) in sheets.enumerated() {
            for (row, columns) in rows {
                for (column, entry) in columns {
                    formulas[FormulaLocation(sheet: sheetIndex, address: CellAddress(row: row, column: column))] = entry
                }
            }
        }
        self.formulas = formulas
    }

    /// 一张表里的公式（整张走一遍，不排序）。
    static func formulas(in cells: SparseGrid<Cell>) -> SheetFormulas {
        var rows: SheetFormulas = [:]
        cells.forEachUnordered { address, cell in
            guard let formula = cell.formula else { return }
            rows[address.row, default: [:]][address.column] = Entry(source: formula.source, arrayRange: formula.arrayRange)
        }
        return rows
    }

    /// 一行里的公式；没有就是 nil。
    static func formulas(inRow row: Int, of cells: SparseGrid<Cell>) -> [Int: Entry]? {
        var columns: [Int: Entry] = [:]
        cells.forEach(inRowUnordered: row) { column, cell in
            guard let formula = cell.formula else { return }
            columns[column] = Entry(source: formula.source, arrayRange: formula.arrayRange)
        }
        return columns.isEmpty ? nil : columns
    }
}

/// 解析过的公式（原文 → 语法树），跨重算留着：一万行的还款表每次重算都把 5 万个公式从头切词、解析一遍，
/// 占了重算的三成多（2026-11-14 实测）。解析只看原文，同一个原文结果一样。条目太多就整个清掉重来，内存有个上限。
final class FormulaParseCache: Sendable {
    static let shared = FormulaParseCache()
    private static let limit = 500_000
    private let storage = Mutex<[String: Result<FormulaNode, FormulaSyntaxError>]>([:])

    func parse(_ source: String) -> Result<FormulaNode, FormulaSyntaxError> {
        if let hit = storage.withLock({ $0[source] }) { return hit }
        let result = Result { () throws(FormulaSyntaxError) -> FormulaNode in try FormulaParser.parse(source) }
        storage.withLock { cache in
            if cache.count >= Self.limit { cache.removeAll(keepingCapacity: true) }
            cache[source] = result
        }
        return result
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
        self.init(layout: FormulaLayout(workbook), workbook: workbook)
    }

    /// `layout` 是 `workbook` 里的公式（FormulaLayout）。计划只由公式的位置、原文和 sheet 名定，和别的格子的值无关。
    init(layout: FormulaLayout, workbook: Workbook) {
        // 每张 sheet 上哪些格子有公式：sheet → 列 → 行（从小到大）。找依赖时按列二分查找。
        var formulaCells: [Int: [Int: [Int]]] = [:]
        for (location, formula) in layout.formulas {
            formulaCells[location.sheet, default: [:]][location.address.column, default: []].append(location.address.row)
            if formula.arrayRange != nil {
                unsupported[location] = "array formulas are not supported yet"
                continue
            }
            switch FormulaParseCache.shared.parse(formula.source) {
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
        // 每张 sheet 有公式的列，从左到右：找依赖时按这个顺序，排出来的计算顺序每次都一样（以前按字典的顺序走，每次启动
        // 可能不同；算出来的值和顺序无关，标哪些格子「循环引用」也和顺序无关，见 topologicalOrder）。
        var formulaColumns: [Int: [(column: Int, rows: [Int])]] = [:]
        for (sheet, columns) in formulaCells {
            formulaColumns[sheet] = columns.keys.sorted().map { (column: $0, rows: columns[$0]!.sorted()) }
        }

        var dependencies: [FormulaLocation: [FormulaLocation]] = [:]
        for (location, node) in parsed {
            var found: [FormulaLocation] = []
            Self.forEachReference(in: node) { reference in
                guard let sheet = reference.sheet.map({ workbook.sheetIndex(named: $0) }) ?? location.sheet,
                      let columns = formulaColumns[sheet] else { return }
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

    /// 计算顺序和循环引用：按强连通分量来（Tarjan，显式的栈，一万层深的链也不爆栈）。
    ///
    /// 一个分量里的公式两两能互相走到：有两个以上、或者只有一个但引用了自己，就是一个环，里面**每一个**都标
    /// 「循环引用」（设计 5.5 节）。分量只由依赖关系定，和从哪开始走、先走哪个引用无关，所以标哪些格子每次都一样。
    /// 原来深度优先碰到「还在栈上的格子」才把栈上那一段标上，同一个环里从别的路走到、当时已经走完的公式会漏标：
    /// A1 = SUM(B1:C1)、B1 = A1、C1 = IFERROR(B1,7)，先走 B1 就漏了 C1，C1 显示 7（2026-11-15，Codex 审 PR #10 时指出，
    /// 自检 circularChecks 复现）。
    ///
    /// Tarjan 给出分量的先后是「被引用的先出来」，一个接一个排起来就是计算顺序：不在环上的公式，它引用的公式都排在它
    /// 前面；在环上的事先都填成错误值，先后无所谓。
    private static func topologicalOrder(_ roots: [FormulaLocation],
                                         _ dependencies: [FormulaLocation: [FormulaLocation]])
        -> ([FormulaLocation], Set<FormulaLocation>) {
        // 位置换成连续的编号（roots 在最前面，按原来的顺序），后面全用数组。
        var ids: [FormulaLocation: Int] = [:]
        var nodes: [FormulaLocation] = []
        ids.reserveCapacity(roots.count)
        nodes.reserveCapacity(roots.count)
        func id(of location: FormulaLocation) -> Int {
            if let known = ids[location] { return known }
            ids[location] = nodes.count
            nodes.append(location)
            return nodes.count - 1
        }
        for root in roots { _ = id(of: root) }
        var edges: [[Int]] = []
        edges.reserveCapacity(nodes.count)
        var next = 0
        while next < nodes.count {   // 引用到的公式（算不了的那些）也编上号，接着往后排
            edges.append((dependencies[nodes[next]] ?? []).map { id(of: $0) })
            next += 1
        }

        var index = [Int](repeating: -1, count: nodes.count)
        var lowlink = [Int](repeating: 0, count: nodes.count)
        var onStack = [Bool](repeating: false, count: nodes.count)
        var component: [Int] = []
        var counter = 0
        var order: [FormulaLocation] = []
        order.reserveCapacity(nodes.count)
        var circular: Set<FormulaLocation> = []
        var calls: [(node: Int, edge: Int)] = []
        func enter(_ node: Int) {
            index[node] = counter
            lowlink[node] = counter
            counter += 1
            component.append(node)
            onStack[node] = true
            calls.append((node, 0))
        }
        for root in roots.indices where index[root] < 0 {
            enter(root)
            while let (node, edge) = calls.last {
                if edge < edges[node].count {
                    calls[calls.count - 1].edge += 1
                    let child = edges[node][edge]
                    if index[child] < 0 {
                        enter(child)
                    } else if onStack[child] {
                        lowlink[node] = min(lowlink[node], index[child])
                    }
                    continue
                }
                calls.removeLast()
                if let parent = calls.last?.node { lowlink[parent] = min(lowlink[parent], lowlink[node]) }
                guard lowlink[node] == index[node] else { continue }
                // node 是一个分量的根：栈上它以上的都是这个分量。
                let start = component.lastIndex(of: node)!
                let members = component[start...]
                let isCycle = members.count > 1 || edges[node].contains(node)
                for member in members {
                    onStack[member] = false
                    order.append(nodes[member])
                    if isCycle { circular.insert(nodes[member]) }
                }
                component.removeSubrange(start...)
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
