import Foundation

/// 一次改动碰到了 SkySheet 写不回去的公式占着的格子（PR #17 第一轮审查第 3、4、5 条，最后一次复查的收尾）。这些格子的内容
/// 不能改，样式可以：
/// - 跟随者的公式算不出来的共享公式组，主格和每一个跟随者。主格一改，跟随者就写不出来了（以前到保存才拒绝，从那以后整本
///   存不了，恢复副本也写不出来）。跟随者以前能单独改，可改了以后记录作废，整轮撤销经 apply 换回快照时又作废一次，`<f>`
///   悄悄丢了（最后一次复查）。和模拟运算表一样整组锁住，要改在 Excel 里改。
/// - 模拟运算表的整个区域，包括它的第一格：Excel 也不让只改一部分（Cannot change part of a data table），改了的值 Excel
///   一重算就被表的结果盖回去。
/// 改之前就拒绝，工作簿一点不动：界面上是 SheetSession.apply，AI 那边是 AIContext.change（在开撤销组之前）。
public struct LockedFormulaChange: Error, Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// 跟随者的公式算不出来的共享公式组占的区域（主格的 `ref`；文件里没有主格时是组里格子围成的范围）。
        case sharedFormula(CellRange)
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
        for (address, record) in storedFormulas where record.dataTableRange(at: address) != nil {
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
        var locked: [(cell: CellAddress, reason: LockedFormulaChange.Reason)] = []
        /// 共享公式组（si）→ 记录还对得上的格子（主格、跟随者）；哪几组有算不出来的跟随者；各组主格的 `ref`。
        var members: [String: [CellAddress]] = [:]
        var unknown: Set<String> = []
        var refs: [String: CellRange] = [:]
        for (address, record) in old.storedFormulas {
            if let range = record.dataTableRange(at: address) {
                var cells: [CellAddress] = [address]
                cells += old.cells.entries(in: range).map { $0.address }
                cells += new.cells.entries(in: range).map { $0.address }
                locked += cells.map { (cell: $0, reason: LockedFormulaChange.Reason.dataTable(range)) }
            }
            guard let shared = record.shared, record.describes(old.cells[address]) else { continue }
            members[shared.group, default: []].append(address)
            if shared.unknown { unknown.insert(shared.group) }
            if !shared.follower, let ref = record.attributes["ref"].flatMap({ CellRange(a1: $0) }) { refs[shared.group] = ref }
        }
        // 最后一次复查的收尾：主格、跟随者整组锁住（以前只锁主格，跟随者能单独改）。
        for group in unknown {
            let cells = members[group] ?? []
            let range = refs[group] ?? enclosing(cells)
            locked += cells.map { (cell: $0, reason: LockedFormulaChange.Reason.sharedFormula(range)) }
        }
        func rank(_ reason: LockedFormulaChange.Reason) -> Int {
            if case .dataTable = reason { return 0 }
            return 1
        }
        let changed = locked.filter { !untouched(old.cells[$0.cell], new.cells[$0.cell]) }
            .min { ($0.cell, rank($0.reason)) < ($1.cell, rank($1.reason)) }
        return changed.map { LockedFormulaChange(sheet: old.name, cell: $0.cell, reason: $0.reason) }
    }

    /// 锁住的格子比得更严：整格（值，公式连同文件里的缓存值和状态）一点没动才算没改，样式不算。写回同样的原文也是改写：
    /// 缓存值没了，算不出来的公式就成了 #NAME?。这些格子 SkySheet 一律不写，粘贴、填充、清空只要碰到就拒绝。
    /// 没碰到的格子在改之前、改之后是同一份（重算在拒绝之后），值和状态不会对不上。
    private static func untouched(_ lhs: Cell?, _ rhs: Cell?) -> Bool {
        (lhs?.value ?? .empty) == (rhs?.value ?? .empty) && lhs?.formula == rhs?.formula
    }

    /// 几格围成的最小区域：文件里没有主格的共享公式组，用它说是哪一片。
    private static func enclosing(_ cells: [CellAddress]) -> CellRange {
        let rows = cells.map { $0.row }, columns = cells.map { $0.column }
        return CellRange(CellAddress(row: rows.min() ?? 0, column: columns.min() ?? 0),
                         CellAddress(row: rows.max() ?? 0, column: columns.max() ?? 0))
    }

    /// 改之前、改之后一格的内容一样不一样（作废记录用；锁住的格子比得更严，见 untouched）：有公式的比原文和数组区域
    /// （值是算出来的），没有公式的比值。样式不算。
    ///
    /// 原文是空的公式（算不出来的跟随者、模拟运算表的第一格）只是个占位，原文说明不了是哪个公式：整格一点没动才算一样。
    /// 粘贴、填充、输入写进来的空原文是新的公式，没有文件里的缓存值、也还没算过，和打开文件时就在那里的总有地方不一样
    /// （打开时整本重算过）。以前只比原文，另一组的跟随者粘过来也算没改（PR #17 第二轮审查第 2 条）。
    private static func sameContent(_ lhs: Cell?, _ rhs: Cell?) -> Bool {
        switch (lhs?.formula, rhs?.formula) {
        case (nil, nil): (lhs?.value ?? .empty) == (rhs?.value ?? .empty)
        case let (left?, right?) where left.source.isEmpty && right.source.isEmpty: left == right && lhs?.value == rhs?.value
        case let (left?, right?): ExactText(left.source) == ExactText(right.source) && left.arrayRange == right.arrayRange
        default: false
        }
    }

    /// 内容被改写过的格子，文件里的 `<f>` 记录作废（StoredFormula.replaced），以后不会再对上（PR #17 第二轮审查第 2 条）。
    /// SheetSession.apply 每一步都在拒绝之后调：输入、清空、粘贴、填充、AI 写入……改工作簿都从那里过；撤销、重做换回的是
    /// 整本快照，记录跟着内容一起回来。按 sheet 编号和 `before` 对上（sameContent）；新出来的表（复制的，记录跟着格子
    /// 一起复制）没有可比的，只看格子还是不是记录里那个公式。整轮撤销也经 apply 换回快照：锁住的格子（算不出来的共享公式组、
    /// 模拟运算表）这一轮里改不了，记录不受影响；别的格子换回来以后记录照旧作废，照常写原文，公式不丢（最后一次复查）。
    public mutating func retireReplacedFormulas(since before: Workbook) {
        let previous = Dictionary(before.sheets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in sheets.indices where !sheets[index].storedFormulas.isEmpty {
            let sheet = sheets[index]
            let old = previous[sheet.id]
            for (address, record) in sheet.storedFormulas where !record.replaced {
                let cell = sheet.cells[address]
                let rewritten = old.map { !Self.sameContent($0.cells[address], cell) } ?? false
                if rewritten || !record.describes(cell) {
                    sheets[index].storedFormulas[address]?.replaced = true
                }
            }
        }
    }
}
