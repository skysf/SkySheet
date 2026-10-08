import Foundation

/// 一个工作簿：几张 sheet、共用的样式表、日期系统。值类型（设计第四节）。
public struct Workbook: Hashable, Sendable {
    public var sheets: [Sheet]
    public var styles: StyleTable
    public var dateSystem: DateSystem
    /// 文件里定义的名称（named range）。第一版公式里不支持，读进来原样留着，保存时写回（设计 5.1 节）。
    public var definedNames: [DefinedName]
    /// 主题的 12 种颜色（RRGGBB），按主题文件里的顺序：dk1、lt1、dk2、lt2、accent1…6、hlink、folHlink。
    /// 样式里的 `theme="1"` 指哪一个有讲究（前四个两两对调），由显示层换算。
    public var themeColors: [String]

    /// Office 默认主题的颜色。文件里没有主题时用它（样例 loan.xlsx 的主题也是这一套）。
    public static let defaultThemeColors = ["000000", "FFFFFF", "44546A", "E7E6E6", "4472C4", "ED7D31",
                                            "A5A5A5", "FFC000", "5B9BD5", "70AD47", "0563C1", "954F72"]

    public init(sheets: [Sheet] = [], styles: StyleTable = StyleTable(), dateSystem: DateSystem = .from1900,
                definedNames: [DefinedName] = [], themeColors: [String] = Workbook.defaultThemeColors) {
        self.sheets = sheets
        self.styles = styles
        self.dateSystem = dateSystem
        self.definedNames = definedNames
        self.themeColors = themeColors
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
