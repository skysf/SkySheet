import Foundation

/// 工作簿的样式表。第一版只用到数字格式；字体、填充、边框的编号先记着，M2 画表格时再用。
public struct StyleTable: Hashable, Sendable {
    /// 文件里 `<numFmts>` 自定义的格式：编号 → 格式代码。
    public var customNumberFormats: [Int: String]
    /// `<cellXfs>`：下标就是单元格的样式编号。
    public var cellFormats: [CellFormat]

    public init(customNumberFormats: [Int: String] = [:], cellFormats: [CellFormat] = [CellFormat()]) {
        self.customNumberFormats = customNumberFormats
        self.cellFormats = cellFormats
    }

    public func numberFormatID(forStyle index: Int) -> Int {
        cellFormats.indices.contains(index) ? cellFormats[index].numberFormatID : 0
    }

    /// 一个样式的数字格式代码：文件里自定义的优先，其次是内置编号表，都没有就是 General。
    public func formatCode(forStyle index: Int) -> String {
        let id = numberFormatID(forStyle: index)
        return customNumberFormats[id] ?? BuiltinFormats.code(for: id) ?? "General"
    }
}

/// xlsx 里 `<cellXfs>` 的一项。
public struct CellFormat: Hashable, Sendable {
    public var numberFormatID: Int
    public var fontID: Int
    public var fillID: Int
    public var borderID: Int
    public var horizontalAlignment: String?
    public var verticalAlignment: String?
    public var wrapText: Bool

    public init(numberFormatID: Int = 0, fontID: Int = 0, fillID: Int = 0, borderID: Int = 0,
                horizontalAlignment: String? = nil, verticalAlignment: String? = nil, wrapText: Bool = false) {
        self.numberFormatID = numberFormatID
        self.fontID = fontID
        self.fillID = fillID
        self.borderID = borderID
        self.horizontalAlignment = horizontalAlignment
        self.verticalAlignment = verticalAlignment
        self.wrapText = wrapText
    }
}
