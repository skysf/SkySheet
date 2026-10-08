import Foundation

/// 一张表。值类型：快照、撤销、「撤销这一轮」都只是复制一份（设计第四节）。
public struct Sheet: Hashable, Sendable {
    /// xlsx 里的 sheetId。新建的 sheet 取工作簿里最大的加一。
    public var id: Int
    public var name: String
    public var role: SheetRole
    public var visibility: SheetVisibility
    public var cells: SparseGrid<Cell>
    /// 列宽和隐藏，按 xlsx 的 `<col min max>` 一段一段记。
    public var columns: [ColumnFormat]
    public var rowFormats: [Int: RowFormat]
    public var frozen: FrozenPanes?
    public var merges: [CellRange]
    /// 页签颜色，xlsx 里的 ARGB 十六进制（如 "FFFFFFFF"）。
    public var tabColor: String?
    public var defaultColumnWidth: Double?
    public var defaultRowHeight: Double?

    public init(id: Int, name: String, role: SheetRole = .original) {
        self.id = id
        self.name = name
        self.role = role
        visibility = .visible
        cells = SparseGrid()
        columns = []
        rowFormats = [:]
        frozen = nil
        merges = []
        tabColor = nil
        defaultColumnWidth = nil
        defaultRowHeight = nil
    }
}

/// 原始数据，还是 AI 写的。原始 sheet 对 AI 只读（设计第 12 条）。
public enum SheetRole: Hashable, Sendable {
    case original
    case ai
}

public enum SheetVisibility: Hashable, Sendable {
    case visible
    case hidden
    /// 只能用 VBA 取消隐藏的那种。
    case veryHidden
}

/// 一段连续的列（从 `first` 到 `last`，都从 0 开始）共用的宽度和隐藏状态。
public struct ColumnFormat: Hashable, Sendable {
    public var first: Int
    public var last: Int
    /// Excel 的列宽单位：默认字体里「0」的个数。
    public var width: Double?
    public var hidden: Bool
    public var styleIndex: Int?

    public init(first: Int, last: Int, width: Double? = nil, hidden: Bool = false, styleIndex: Int? = nil) {
        self.first = first
        self.last = last
        self.width = width
        self.hidden = hidden
        self.styleIndex = styleIndex
    }
}

public struct RowFormat: Hashable, Sendable {
    /// 行高，单位是磅。
    public var height: Double?
    public var hidden: Bool
    public var styleIndex: Int?

    public init(height: Double? = nil, hidden: Bool = false, styleIndex: Int? = nil) {
        self.height = height
        self.hidden = hidden
        self.styleIndex = styleIndex
    }
}

/// 冻结窗格：上面冻住几行、左边冻住几列。
public struct FrozenPanes: Hashable, Sendable {
    public var rows: Int
    public var columns: Int

    public init(rows: Int, columns: Int) {
        self.rows = rows
        self.columns = columns
    }
}
