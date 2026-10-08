import Foundation

/// 查找函数。只返回单个值（不做动态数组的「溢出」）。
enum LookupFunctions {
    static let all: [FunctionSpec] = [
        FunctionSpec("VLOOKUP", 3...4, verticalLookup),
        FunctionSpec("MATCH", 2...3, match),
        FunctionSpec("INDEX", 2...3, index),
        FunctionSpec("XLOOKUP", 3...6, xlookup),
    ]

    /// VLOOKUP(值, 表, 第几列, [近似=TRUE])。近似匹配要求第一列从小到大排好：取不超过它的最后一行。
    private static func verticalLookup(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        let target = try lookupValue(arguments, 0)
        let table = try arguments.grid(1)
        let column = try arguments.integer(2)
        guard column >= 1 else { throw CellError.value }
        guard column <= table.columns else { throw CellError.ref }
        let keys = (0..<table.rows).map { table[$0, 0] }
        let row = try arguments.bool(3, default: true)
            ? lastNotGreater(target, in: keys)
            : exactIndex(of: target, in: keys, wildcards: true)
        guard let row else { throw CellError.na }
        return table[row, column - 1]
    }

    /// MATCH(值, 一行或一列, [方式=1])：1 不超过它的最后一个（从小到大排好），0 精确，-1 不小于它的最后一个（从大到小排好）。
    /// 返回从 1 数起的位置。
    private static func match(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        let target = try lookupValue(arguments, 0)
        let list = try arguments.grid(1)
        guard list.isVector else { throw CellError.na }
        let found: Int? = switch try arguments.integer(2, default: 1) {
        case 0: exactIndex(of: target, in: list.values, wildcards: true)
        case let mode where mode > 0: lastNotGreater(target, in: list.values)
        default: lastNotLess(target, in: list.values)
        }
        guard let found else { throw CellError.na }
        return .number(Decimal(found + 1))
    }

    /// INDEX(区域, 行, [列])。只有一行的区域，INDEX(区域, n) 的 n 是列号。
    /// 行或列给 0（取整行整列）要返回数组，第一版不支持，报 #VALUE!。
    private static func index(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        var row = try arguments.integer(1)
        var column = try arguments.integer(2, default: 1)
        guard let area = arguments.area(0) else {
            guard row <= 1, column <= 1 else { throw CellError.ref }
            return arguments.scalar(0)
        }
        let range = area.range
        if arguments.isOmitted(2) {
            if range.rowCount == 1 {
                (row, column) = (1, row)
            } else if range.columnCount > 1 {
                throw CellError.value
            }
        }
        guard row >= 1, column >= 1 else { throw CellError.value }
        guard row <= range.rowCount, column <= range.columnCount else { throw CellError.ref }
        return arguments.context.value(sheet: area.sheet,
                                       at: CellAddress(row: range.start.row + row - 1, column: range.start.column + column - 1))
    }

    /// XLOOKUP(值, 查找的一行或一列, 返回的区域, [找不到时], [匹配方式=0], [搜索方式=1])。
    /// 匹配方式：0 精确，-1 精确或下一个较小的，1 精确或下一个较大的，2 通配符。搜索方式：1 从头，-1 从尾（2、-2 当 1、-1）。
    private static func xlookup(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        let target = try lookupValue(arguments, 0)
        let keys = try arguments.grid(1)
        guard keys.isVector else { throw CellError.value }
        let results = try arguments.grid(2, shapedLike: keys)
        let mode = try arguments.integer(4, default: 0)
        let fromEnd = try arguments.integer(5, default: 1) < 0
        var order = Array(keys.values.indices)
        if fromEnd { order.reverse() }
        let ordered = order.map { keys.values[$0] }

        var found = exactIndex(of: target, in: ordered, wildcards: mode == 2)
        if found == nil, mode == 1 || mode == -1 {
            found = nearest(target, in: ordered, larger: mode == 1)
        }
        guard let found else {
            if arguments.count > 3, !arguments.isOmitted(3) { return arguments.scalar(3) }
            throw CellError.na
        }
        return results.values[order[found]]
    }

    // MARK: - 共用的部分

    private static func lookupValue(_ arguments: FunctionArguments, _ index: Int) throws(CellError) -> CellValue {
        let value = arguments.scalar(index)
        if case .error(let error) = value { throw error }
        return value
    }

    /// 精确匹配：数字按值，文字不分大小写（`wildcards` 时认 * ? ~），逻辑值按值。空格子不匹配任何东西。
    static func exactIndex(of target: CellValue, in list: [CellValue], wildcards: Bool) -> Int? {
        if case .text(let pattern) = target, wildcards, pattern.contains(where: { "*?~".contains($0) }) {
            return list.firstIndex { value in
                if case .text(let text) = value { return Wildcard.matches(text, pattern: pattern) }
                return false
            }
        }
        return list.firstIndex { sameType($0, target) && Operators.compare($0, target) == .orderedSame }
    }

    /// 从小到大排好的列表里，不超过 target 的最后一个（同类型才比）。碰到比它大的就停：和 Excel 在排好的数据上结果一样。
    static func lastNotGreater(_ target: CellValue, in list: [CellValue]) -> Int? {
        var found: Int?
        for (index, value) in list.enumerated() where sameType(value, target) {
            guard Operators.compare(value, target) != .orderedDescending else { break }
            found = index
        }
        return found
    }

    /// 从大到小排好的列表里，不小于 target 的最后一个。
    static func lastNotLess(_ target: CellValue, in list: [CellValue]) -> Int? {
        var found: Int?
        for (index, value) in list.enumerated() where sameType(value, target) {
            guard Operators.compare(value, target) != .orderedAscending else { break }
            found = index
        }
        return found
    }

    /// 不要求排好序：比 target 大的里面最小的（`larger`），或者比它小的里面最大的。
    private static func nearest(_ target: CellValue, in list: [CellValue], larger: Bool) -> Int? {
        var best: Int?
        for (index, value) in list.enumerated() where sameType(value, target) {
            let side = Operators.compare(value, target)
            guard side == (larger ? .orderedDescending : .orderedAscending) else { continue }
            if let current = best {
                let better = Operators.compare(value, list[current]) == (larger ? .orderedAscending : .orderedDescending)
                if better { best = index }
            } else {
                best = index
            }
        }
        return best
    }

    private static func sameType(_ a: CellValue, _ b: CellValue) -> Bool {
        switch (a, b) {
        case (.number, .number), (.text, .text), (.bool, .bool): true
        default: false
        }
    }
}
