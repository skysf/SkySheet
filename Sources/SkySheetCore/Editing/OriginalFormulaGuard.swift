import Foundation

/// AI 的一个操作会连带改掉原始 sheet 里公式的原文（设计第 12 条：原始 sheet 对 AI 只读，间接的也不行）。
public struct OriginalFormulasWouldChange: Error, Equatable, Sendable {
    /// 公式原文会变的格子，写成公式里的样子（`Loan!A1`，sheet 名要引号就带引号），按 sheet 的顺序、再按行列排。
    public var cells: [String]

    public init(cells: [String]) {
        self.cells = cells
    }
}

extension Workbook {
    /// 在副本上做 `edit`，原始 sheet（不是 AI 的那些）里有公式原文变了就整个不做、抛出这些格子，工作簿一点不动。
    ///
    /// 改名、删表、插删行列和 Excel 一样整本联动改公式：用户自己做的时候就该这样（界面上照旧）。AI 在自己的 sheet 上做时，
    /// 原始 sheet 里指着它的公式也会跟着变（引用改名、平移，删掉的变成 #REF!），等于间接改了原始数据
    /// （2026-11-16 排查第 3 条）。不做「只改 AI 那部分、原始的不改」：引用不跟着改，原始 sheet 的公式就悄悄指错了格子。
    public mutating func editSparingOriginalFormulas(_ edit: (inout Workbook) throws -> Void) throws {
        var edited = self
        try edit(&edited)
        let changed = edited.originalFormulasChanged(since: self)
        guard changed.isEmpty else { throw OriginalFormulasWouldChange(cells: changed) }
        self = edited
    }

    /// 和 `before` 比，原始 sheet 里公式原文变了的格子。按 sheet 的编号对上（删表、挪表以后下标会变）；`before` 里的
    /// 原始 sheet 在这里找不到就跳过：AI 删不了原始 sheet（写入类工具先过 requireAISheet）。
    private func originalFormulasChanged(since before: Workbook) -> [String] {
        let now = Dictionary(sheets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [String] = []
        for sheet in before.sheets where !sheet.role.isAI {
            guard let after = now[sheet.id] else { continue }
            var changed: [CellAddress] = []
            sheet.cells.forEachUnordered { address, cell in
                // 按标量比（ExactText）：String 的 == 把规范等价的两种写法当成一样，原文换了写法也看不出来。
                guard let source = cell.formula?.source,
                      after.cells[address]?.formula.map({ ExactText($0.source) }) != ExactText(source) else { return }
                changed.append(address)
            }
            let name = FormulaRewriter.quotedSheetName(sheet.name)
            result += changed.sorted { ($0.row, $0.column) < ($1.row, $1.column) }.map { "\(name)!\($0.a1)" }
        }
        return result
    }
}
