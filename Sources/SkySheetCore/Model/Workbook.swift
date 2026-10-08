import Foundation

/// 一个工作簿：几张 sheet、共用的样式表、日期系统。值类型（设计第四节）。
public struct Workbook: Hashable, Sendable {
    public var sheets: [Sheet]
    public var styles: StyleTable
    public var dateSystem: DateSystem
    /// 文件里定义的名称（named range）。第一版公式里不支持，读进来原样留着，保存时写回（设计 5.1 节）。
    public var definedNames: [DefinedName]

    public init(sheets: [Sheet] = [], styles: StyleTable = StyleTable(), dateSystem: DateSystem = .from1900,
                definedNames: [DefinedName] = []) {
        self.sheets = sheets
        self.styles = styles
        self.dateSystem = dateSystem
        self.definedNames = definedNames
    }

    /// Excel 的 sheet 名不分大小写：公式里写 `loan!A1` 也指 Loan。
    public func sheetIndex(named name: String) -> Int? {
        sheets.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// 日期序列号从哪天算起。Windows 版 Excel、腾讯文档都是 1900；老的 Mac 版 Excel 文件可能是 1904。
public enum DateSystem: Hashable, Sendable {
    case from1900
    case from1904
}

public struct DefinedName: Hashable, Sendable {
    public var name: String
    /// 定义它的公式（通常是一个区域，如 `Loan!$A$1:$B$9`），不带 "="。
    public var formula: String
    /// 只在某张 sheet 里有效时，那张 sheet 在工作簿里的位置。
    public var sheetIndex: Int?

    public init(name: String, formula: String, sheetIndex: Int? = nil) {
        self.name = name
        self.formula = formula
        self.sheetIndex = sheetIndex
    }
}
