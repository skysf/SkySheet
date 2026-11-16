import Foundation

/// 一次改动碰到了 SkySheet 写不回去的公式占着的格子（PR #17 第一轮审查第 3、4、5 条）。这些格子的内容不能改，样式可以：
/// - 跟随者的公式算不出来的共享公式组的主格：主格一改，跟随者就写不出来了。以前允许改、到保存才拒绝，从那以后整本存不了，
///   恢复副本也写不出来；
/// - 模拟运算表的整个区域，包括它的第一格：Excel 也不让只改一部分（Cannot change part of a data table），改了的值 Excel
///   一重算就被表的结果盖回去。
/// 改之前就拒绝，工作簿一点不动：界面上是 SheetSession.apply，AI 那边是 AIContext.change（在开撤销组之前）。
public struct LockedFormulaChange: Error, Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// `follower` 这一格（可能还有别的）从这一格平移出公式，SkySheet 算不出来是什么。
        case sharedFormula(follower: CellAddress)
        /// 模拟运算表占的区域。
        case dataTable(CellRange)
    }

    public var sheet: String
    public var cell: CellAddress
    public var reason: Reason

    public init(sheet: String, cell: CellAddress, reason: Reason) {
        self.sheet = sheet
        self.cell = cell
        self.reason = reason
    }
}

extension Sheet {
    /// 这张表上模拟运算表的第一格（有好几个时取最前面的）。有模拟运算表的表不能插删行列：它按位置指着结果区和输入格，
    /// 插删以后就指错了，Excel 会拿错的输入格算。
    public var dataTableCell: CellAddress? {
        var first: CellAddress?
        for (address, record) in storedFormulas where record.attributes["t"] == "dataTable" {
            if first.map({ address < $0 }) ?? true { first = address }
        }
        return first
    }
}

extension Workbook {
    /// 和 `before` 比，改动有没有碰到这些格子的内容（按 sheet 编号对上；整张删掉的不算，格子跟着表一起没了）。
    /// 先在副本上改、再拿它问：有就整个不做。
    public func lockedFormulaChange(since before: Workbook) -> LockedFormulaChange? {
        guard before.sheets.contains(where: { !$0.storedFormulas.isEmpty }) else { return nil }
        let now = Dictionary(sheets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for old in before.sheets where !old.storedFormulas.isEmpty {
            guard let new = now[old.id] else { continue }
            if let change = Self.lockedChange(from: old, to: new) { return change }
        }
        return nil
    }

    private static func lockedChange(from old: Sheet, to new: Sheet) -> LockedFormulaChange? {
        func same(_ address: CellAddress) -> Bool { sameContent(old.cells[address], new.cells[address]) }
        var tables: [(cell: CellAddress, range: CellRange)] = []
        /// 主格 → 还在组里（改之前原文没变）的、公式算不出来的跟随者里最前面的那一格。都被改掉了，主格就能改了。
        var masters: [CellAddress: CellAddress] = [:]
        for (address, record) in old.storedFormulas {
            if let range = record.dataTableRange(at: address) { tables.append((cell: address, range: range)) }
            guard let shared = record.shared, shared.unknown, let master = shared.master,
                  let formula = old.cells[address]?.formula, ExactText(formula.source) == ExactText(record.source) else { continue }
            masters[master] = min(masters[master] ?? address, address)
        }
        for table in tables.sorted(by: { $0.cell < $1.cell }) {
            var cells: [CellAddress] = [table.cell]
            cells += old.cells.entries(in: table.range).map { $0.address }
            cells += new.cells.entries(in: table.range).map { $0.address }
            if let changed = cells.sorted().first(where: { !same($0) }) {
                return LockedFormulaChange(sheet: old.name, cell: changed, reason: .dataTable(table.range))
            }
        }
        for (master, follower) in masters.sorted(by: { $0.key < $1.key }) where !same(master) {
            return LockedFormulaChange(sheet: old.name, cell: master, reason: .sharedFormula(follower: follower))
        }
        return nil
    }

    /// 内容一样不一样：有公式的比原文和数组区域（值是算出来的），没有公式的比值。样式不算。
    private static func sameContent(_ lhs: Cell?, _ rhs: Cell?) -> Bool {
        switch (lhs?.formula, rhs?.formula) {
        case (nil, nil): (lhs?.value ?? .empty) == (rhs?.value ?? .empty)
        case let (left?, right?): ExactText(left.source) == ExactText(right.source) && left.arrayRange == right.arrayRange
        default: false
        }
    }
}
