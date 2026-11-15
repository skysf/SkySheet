import Foundation

/// 按条件求和、计数、求平均。条件的规则都在 `Criterion` 里（设计 5.2 节）。
/// 条件区域和求和区域按位置对齐：第 i 行第 j 列对第 i 行第 j 列。
enum ConditionalFunctions {
    static let all: [FunctionSpec] = [
        FunctionSpec("SUMIF", 2...3, sumIf),
        FunctionSpec("SUMIFS", 3...FunctionSpec.many, sumIfs),
        FunctionSpec("COUNTIF", 2...2, countIf),
        FunctionSpec("COUNTIFS", 2...FunctionSpec.many, countIfs),
        FunctionSpec("AVERAGEIF", 2...3, averageIf),
        FunctionSpec("AVERAGEIFS", 3...FunctionSpec.many, averageIfs),
    ]

    /// SUMIF(区域, 条件, [求和区域])：求和区域从它自己的左上角开始、取和条件区域一样的大小（Excel 就是这样）。
    private static func sumIf(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        let range = try arguments.conditionalRange(0)
        let target = arguments.isOmitted(2) ? range : try arguments.conditionalRange(2, shapedLike: range, expand: true)
        return .number(try total(of: target, matching: [(range, try criterion(arguments, 1))]).sum)
    }

    /// SUMIFS(求和区域, 条件区域1, 条件1, …)。
    private static func sumIfs(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        let target = try arguments.conditionalRange(0)
        return .number(try total(of: target, matching: try pairs(arguments, from: 1, shape: target)).sum)
    }

    private static func countIf(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        let range = try arguments.conditionalRange(0)
        return .number(Decimal(countMatching([(range, try criterion(arguments, 1))])))
    }

    /// COUNTIFS(条件区域1, 条件1, …)：第一个条件区域定大小。
    private static func countIfs(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        let shape = try arguments.conditionalRange(0)
        return .number(Decimal(countMatching(try pairs(arguments, from: 0, shape: shape))))
    }

    private static func averageIf(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        let range = try arguments.conditionalRange(0)
        let target = arguments.isOmitted(2) ? range : try arguments.conditionalRange(2, shapedLike: range, expand: true)
        let (sum, count) = try total(of: target, matching: [(range, try criterion(arguments, 1))])
        guard count > 0 else { throw CellError.div0 }
        return .number(sum / Decimal(count))
    }

    private static func averageIfs(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        let target = try arguments.conditionalRange(0)
        let (sum, count) = try total(of: target, matching: try pairs(arguments, from: 1, shape: target))
        guard count > 0 else { throw CellError.div0 }
        return .number(sum / Decimal(count))
    }

    // MARK: - 共用的部分

    private static func criterion(_ arguments: FunctionArguments, _ index: Int) throws(CellError) -> Criterion {
        let value = arguments.scalar(index)
        if case .error(let error) = value { throw error }
        return Criterion(value)
    }

    /// 从 `first` 开始的「区域, 条件」对。每个区域的原始大小都要和第一个一样，否则是 #VALUE!。
    private static func pairs(_ arguments: FunctionArguments, from first: Int, shape: ConditionalRange) throws(CellError)
        -> [(ConditionalRange, Criterion)] {
        guard (arguments.count - first) % 2 == 0 else { throw CellError.value }
        // 大小的基准是第 0 个参数：SUMIFS 的求和区域、COUNTIFS 的第一个条件区域。
        var result: [(ConditionalRange, Criterion)] = []
        for index in stride(from: first, to: arguments.count, by: 2) {
            result.append((try arguments.conditionalRange(index, shapedLike: shape), try criterion(arguments, index + 1)))
        }
        return result
    }

    /// 各区域已按位置排序；游标只向前走一次，空白并集也不用额外的字典或集合。
    private static func matches(_ position: Int, _ pairs: [(ConditionalRange, Criterion)], cursors: inout [Int]) -> Bool {
        for index in pairs.indices {
            let (range, criterion) = pairs[index]
            while cursors[index] < range.entries.count, range.entries[cursors[index]].position < position { cursors[index] += 1 }
            let cursor = cursors[index]
            let value = cursor < range.entries.count && range.entries[cursor].position == position ? range.entries[cursor].value : .empty
            if !criterion.matches(value) { return false }
        }
        return true
    }

    private static func countMatching(_ pairs: [(ConditionalRange, Criterion)]) -> Int {
        guard let first = pairs.first else { return 0 }
        // 最常见的单条件不需要合并区域，直接加上未存储的空白格数。
        if pairs.count == 1 {
            return (first.1.matches(.empty) ? first.0.count - first.0.entries.count : 0)
                + first.0.entries.reduce(0) { $0 + (first.1.matches($1.value) ? 1 : 0) }
        }
        var cursors = Array(repeating: 0, count: pairs.count)
        var occupied = 0
        var count = 0
        while true {
            var next: Int?
            for index in pairs.indices {
                let entries = pairs[index].0.entries
                if cursors[index] < entries.count {
                    let position = entries[cursors[index]].position
                    next = min(next ?? position, position)
                }
            }
            guard let position = next else { break }
            occupied += 1
            if matches(position, pairs, cursors: &cursors) { count += 1 }
            for index in pairs.indices {
                let entries = pairs[index].0.entries
                if cursors[index] < entries.count, entries[cursors[index]].position == position { cursors[index] += 1 }
            }
        }
        return count + (pairs.allSatisfy { $0.1.matches(.empty) } ? first.0.count - occupied : 0)
    }

    /// Decimal 有效位有限，按行序求和，避免存储布局改变末位；错误只从匹配的位置上传。
    private static func total(of grid: ConditionalRange, matching pairs: [(ConditionalRange, Criterion)])
        throws(CellError) -> (sum: Decimal, count: Int) {
        var sum: Decimal = 0
        var count = 0
        // 先用首个条件筛选，只有通过的位置才碰其余条件；常见单条件只需一个整数游标。
        let (range, criterion) = pairs[0]
        let remaining = Array(pairs.dropFirst())
        var cursors = Array(repeating: 0, count: remaining.count)
        var cursor = 0
        for (position, value) in grid.entries {
            while cursor < range.entries.count, range.entries[cursor].position < position { cursor += 1 }
            let candidate = cursor < range.entries.count && range.entries[cursor].position == position ? range.entries[cursor].value : .empty
            guard criterion.matches(candidate), remaining.isEmpty || matches(position, remaining, cursors: &cursors) else { continue }
            try add(value, to: &sum, count: &count)
        }
        return (try Operators.checked(sum), count)
    }

    private static func add(_ value: CellValue, to sum: inout Decimal, count: inout Int) throws(CellError) {
        switch value {
        case .number(let number):
            sum += number
            count += 1
        case .error(let error): throw error
        default: break
        }
    }
}
