import Foundation

/// 插入、删除行列（设计第 11 条：第一版没做；2026-10-14 作者定在 M5 做，只在「安全的表」上做，安全不安全由
/// SkySheetFiles 的 StructureLock 判断）。一次插删要连带改的东西都在这里：这张表的格子、行高列宽、合并单元格、冻结窗格、
/// 数组公式的范围、富文本的记录，以及整本里所有指向这张表的公式和定义的名称。
public enum StructureEditError: Error, Equatable, Sendable {
    /// 插进来会把有内容的格子挤出表外（Excel 也不让）。
    case wouldPushContentOffSheet
    /// 这个公式 SkySheet 切不了词，没法替它改引用：不能悄悄跳过，否则它指的格子就错了。
    case unreadableFormula(sheet: String, cell: CellAddress)
    /// 这个定义的名称读不懂，又提到了这张表。
    case unreadableName(String)
    /// 只插删数组公式占的一部分（Excel 也不让）。
    case splitsArrayFormula(CellRange)
}

/// 插删以后哪些公式跟着改了引用：给 AI 的结果、界面的提示用。
public struct StructureEditReport: Equatable, Sendable {
    /// 引用跟着改了的公式个数（整本）。
    public var updatedFormulas = 0
    /// 引用的格子被删掉、变成 #REF! 的公式（挪完以后的位置，最多记 50 个）。
    public var brokenFormulas: [FormulaLocation] = []

    public init() {}
}

extension Workbook {
    /// 在第 `position` 行（列）前面插入 `count` 行（列），原来的往下（往右）挪。新行照抄上面那一行的样式和行高
    /// （新列照抄左边那一列的），和 Excel 的「格式同上」一样。
    @discardableResult
    public mutating func insert(_ count: Int, _ axis: SheetAxis, at position: Int,
                                sheet index: Int) throws(StructureEditError) -> StructureEditReport {
        try shiftLines(.insert(count, at: position, axis), sheet: index)
    }

    /// 删掉几行（列），下面的往上（右边的往左）挪。指向删掉的格子的引用变成 #REF!。
    @discardableResult
    public mutating func delete(_ lines: ClosedRange<Int>, _ axis: SheetAxis,
                                sheet index: Int) throws(StructureEditError) -> StructureEditReport {
        try shiftLines(.delete(lines, axis), sheet: index)
    }

    /// 先检查、先把要改的公式都算好，最后一起换上去：中途报错时工作簿一点没变。
    public mutating func shiftLines(_ shift: LineShift, sheet index: Int) throws(StructureEditError) -> StructureEditReport {
        let target = sheets[index]
        try Self.checkShift(shift, on: target)
        var report = StructureEditReport()
        let rewritten = try rewrittenFormulas(for: shift, sheet: index, report: &report)
        let names = try rewrittenNames(for: shift, sheetName: target.name)

        var sheet = target
        sheet.cells = Self.movedCells(of: target, shift, formulas: rewritten[index] ?? [:])
        sheet.richTextSources = Dictionary(uniqueKeysWithValues: target.richTextSources.compactMap { address, entry in
            shift.map(shift.axis.index(of: address)).map { (shift.axis.moving(address, to: $0), entry) }
        })
        Self.moveFormats(of: &sheet, from: target, shift)
        sheet.merges = target.merges.compactMap { merge in
            shift.map(merge).flatMap { $0.rowCount * $0.columnCount > 1 ? $0 : nil }
        }
        if let frozen = target.frozen {
            // 冻结线跟着内容走：在冻结的那几行里插，冻结的行数跟着变多；删掉其中几行，跟着变少。
            let count = shift.axis == .rows ? frozen.rows : frozen.columns
            let kept = count > 0 ? (shift.map(0...(count - 1)).map { $0.upperBound + 1 } ?? 0) : 0
            sheet.freeze(rows: shift.axis == .rows ? kept : frozen.rows, columns: shift.axis == .columns ? kept : frozen.columns)
        }

        for (sheetIndex, changes) in rewritten where sheetIndex != index {
            for (address, source) in changes {
                sheets[sheetIndex].cells[address]?.formula?.source = source
            }
        }
        sheets[index] = sheet
        definedNames = names
        return report
    }

    // MARK: - 先检查

    private static func checkShift(_ shift: LineShift, on sheet: Sheet) throws(StructureEditError) {
        let everything = CellRange(CellAddress(row: 0, column: 0),
                                   CellAddress(row: CellAddress.maxRows - 1, column: CellAddress.maxColumns - 1))
        if shift.kind == .insert {
            let edge = shift.axis.replacing((shift.axis.limit - shift.count)...(shift.axis.limit - 1), in: everything)
            if sheet.cells.entries(in: edge).contains(where: { $0.value.value != .empty || $0.value.formula != nil }) {
                throw StructureEditError.wouldPushContentOffSheet
            }
        }
        var problem: CellRange?
        sheet.cells.forEach { _, cell in
            guard problem == nil, let range = cell.formula?.arrayRange else { return }
            let span = shift.axis.span(of: range)
            switch shift.kind {
            case .insert:
                if span.lowerBound < shift.start, shift.start <= span.upperBound { problem = range }
            case .delete:
                let lines = shift.lines
                let overlaps = span.lowerBound <= lines.upperBound && lines.lowerBound <= span.upperBound
                let covered = lines.lowerBound <= span.lowerBound && span.upperBound <= lines.upperBound
                if overlaps, !covered { problem = range }
            }
        }
        if let problem { throw StructureEditError.splitsArrayFormula(problem) }
    }

    // MARK: - 公式和名称

    /// 整本里引用跟着变的公式：sheet 下标 → 格子（挪之前的位置）→ 新的原文。这张表上的公式都要看（不写 sheet 名的引用
    /// 就指它）；别的表只看提到了这张表名字的。
    private func rewrittenFormulas(for shift: LineShift, sheet index: Int,
                                   report: inout StructureEditReport) throws(StructureEditError) -> [Int: [CellAddress: String]] {
        let name = sheets[index].name
        var result: [Int: [CellAddress: String]] = [:]
        for (sheetIndex, sheet) in sheets.enumerated() {
            let local = sheetIndex == index
            var changes: [CellAddress: String] = [:]
            var unreadable: CellAddress?
            sheet.cells.forEach { address, cell in
                guard unreadable == nil, let source = cell.formula?.source,
                      local || Self.mentions(source, sheet: name) else { return }
                guard let shifted = FormulaRewriter.shiftLines(in: source, sheet: name, local: local, shift) else {
                    unreadable = address
                    return
                }
                guard shifted != source else { return }
                changes[address] = shifted
                report.updatedFormulas += 1
                if Self.referenceErrors(in: shifted) > Self.referenceErrors(in: source), report.brokenFormulas.count < 50 {
                    let moved = local ? shift.map(shift.axis.index(of: address)).map { shift.axis.moving(address, to: $0) } : address
                    if let moved { report.brokenFormulas.append(FormulaLocation(sheet: sheetIndex, address: moved)) }
                }
            }
            if let unreadable { throw StructureEditError.unreadableFormula(sheet: sheet.name, cell: unreadable) }
            if !changes.isEmpty { result[sheetIndex] = changes }
        }
        return result
    }

    /// 定义的名称里写了这张表的引用（打印区域、命名区域……）一起改。名称里的引用总带着 sheet 名。
    private func rewrittenNames(for shift: LineShift, sheetName name: String) throws(StructureEditError) -> [DefinedName] {
        var names = definedNames
        for position in names.indices where Self.mentions(names[position].formula, sheet: name) {
            guard let shifted = FormulaRewriter.shiftLines(in: names[position].formula, sheet: name, local: false, shift) else {
                throw StructureEditError.unreadableName(names[position].name)
            }
            names[position].formula = shifted
        }
        return names
    }

    /// 公式原文里有没有这张表的名字（不分大小写；名字里的单引号在公式里写成两个）。只是先筛一遍，真改的时候按词认。
    private static func mentions(_ formula: String, sheet name: String) -> Bool {
        formula.range(of: name, options: .caseInsensitive) != nil
            || formula.range(of: name.replacingOccurrences(of: "'", with: "''"), options: .caseInsensitive) != nil
    }

    private static func referenceErrors(in formula: String) -> Int {
        formula.uppercased().components(separatedBy: "#REF!").count - 1
    }

    // MARK: - 格子、行高列宽

    /// 这张表的格子挪到新位置：删掉的不要，公式换成改过引用的原文，数组公式的范围跟着挪。
    /// 插入的新行照抄上面那一行每一格的样式（空格子，只有样式）。
    private static func movedCells(of sheet: Sheet, _ shift: LineShift, formulas: [CellAddress: String]) -> SparseGrid<Cell> {
        let axis = shift.axis
        var cells = SparseGrid<Cell>()
        sheet.cells.forEach { address, cell in
            guard let line = shift.map(axis.index(of: address)) else { return }
            var moved = cell
            if let source = formulas[address] { moved.formula?.source = source }
            if let range = moved.formula?.arrayRange { moved.formula?.arrayRange = shift.map(range) }
            cells[axis.moving(address, to: line)] = moved
        }
        guard shift.kind == .insert, shift.start > 0 else { return cells }
        let template = shift.start - 1
        let everything = CellRange(CellAddress(row: 0, column: 0),
                                   CellAddress(row: CellAddress.maxRows - 1, column: CellAddress.maxColumns - 1))
        for (address, cell) in sheet.cells.entries(in: axis.replacing(template...template, in: everything))
        where cell.styleIndex != 0 {
            for line in shift.start..<min(shift.start + shift.count, axis.limit) {
                cells[axis.moving(address, to: line)] = Cell(styleIndex: cell.styleIndex)
            }
        }
        return cells
    }

    /// 行高（或列宽）跟着挪；插入的新行照抄上面那一行的行高和样式（不照抄隐藏）。
    private static func moveFormats(of sheet: inout Sheet, from original: Sheet, _ shift: LineShift) {
        let inserted = shift.kind == .insert && shift.start > 0
        let newLines = shift.start..<min(shift.start + shift.count, shift.axis.limit)
        switch shift.axis {
        case .rows:
            var formats: [Int: RowFormat] = [:]
            for (row, format) in original.rowFormats {
                if let moved = shift.map(row) { formats[moved] = format }
            }
            if inserted, var template = original.rowFormats[shift.start - 1] {
                template.hidden = false
                if template != RowFormat() {
                    for line in newLines { formats[line] = template }
                }
            }
            sheet.rowFormats = formats
        case .columns:
            var formats = original.columns.compactMap { format -> ColumnFormat? in
                guard let span = shift.map(format.first...format.last) else { return nil }
                var moved = format
                moved.first = span.lowerBound
                moved.last = span.upperBound
                return moved
            }
            // 插在一段中间时这一段已经撑大、盖住了新列；插在一段的开头时新列照抄左边那一列。
            if inserted, !newLines.isEmpty, !formats.contains(where: { ($0.first...$0.last).contains(shift.start) }),
               var template = original.columns.first(where: { ($0.first...$0.last).contains(shift.start - 1) }) {
                template.hidden = false
                template.first = newLines.lowerBound
                template.last = newLines.upperBound - 1
                formats.append(template)
            }
            sheet.columns = Sheet.normalized(formats)
        }
    }
}
