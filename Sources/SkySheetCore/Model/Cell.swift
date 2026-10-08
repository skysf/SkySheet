import Foundation

/// 一个格子：值、（可选的）公式、样式编号（xlsx 里 `<c s="…">`，指向 `StyleTable.cellFormats`）。
public struct Cell: Hashable, Sendable {
    /// 字面值，或者公式算出来的值。
    public var value: CellValue
    public var formula: CellFormula?
    public var styleIndex: Int

    public init(value: CellValue = .empty, formula: CellFormula? = nil, styleIndex: Int = 0) {
        self.value = value
        self.formula = formula
        self.styleIndex = styleIndex
    }
}

/// 格子里的公式。
public struct CellFormula: Hashable, Sendable {
    /// 公式原文，不带开头的 "="。函数名保留文件里的写法（包括 `_xlfn.` 这类前缀），保存时原样写回。
    public var source: String
    /// 文件里存的计算结果（腾讯文档 / Excel 算的）。我们算不了的公式就显示它（设计 5.3 节）。
    public var cachedValue: CellValue?
    /// 数组公式（xlsx 里 `<f t="array" ref="…">`）占的区域。第一版不重算数组公式。
    public var arrayRange: CellRange?
    public var status: FormulaStatus

    public init(source: String, cachedValue: CellValue? = nil, arrayRange: CellRange? = nil,
                status: FormulaStatus = .pending) {
        self.source = source
        self.cachedValue = cachedValue
        self.arrayRange = arrayRange
        self.status = status
    }
}

public enum FormulaStatus: Hashable, Sendable {
    /// 刚从文件读进来，还没重算过。
    case pending
    case calculated
    /// 我们算不了（不认识的函数、数组公式、定义的名称……）：格子显示文件里的缓存值。
    /// 原因给界面和 AI 看（设计 5.3 节「未重算」）。
    case notRecalculated(String)
}
