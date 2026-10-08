import Foundation
import SkySheetCore

/// xlsx 里用到的命名空间、关系类型、内容类型。
enum OOXML {
    static let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    static let relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static let packageRelationships = "http://schemas.openxmlformats.org/package/2006/relationships"
    static let contentTypes = "http://schemas.openxmlformats.org/package/2006/content-types"

    static let officeDocumentType = relationships + "/officeDocument"
    static let worksheetType = relationships + "/worksheet"
    static let stylesType = relationships + "/styles"
    static let sharedStringsType = relationships + "/sharedStrings"
    static let extendedPropertiesType = relationships + "/extended-properties"
    static let corePropertiesType = packageRelationships + "/metadata/core-properties"

    static let workbookContent = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"
    static let worksheetContent = "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"
    static let stylesContent = "application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"
    static let sharedStringsContent = "application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"
    static let coreContent = "application/vnd.openxmlformats-package.core-properties+xml"
    static let appContent = "application/vnd.openxmlformats-officedocument.extended-properties+xml"
    static let relationshipsContent = "application/vnd.openxmlformats-package.relationships+xml"

    /// Strict Open XML 的主命名空间。这种文件读得了，在上面改着写回去还不支持（XLSXWriteError.strictFormat）。
    static let strictMain = "http://purl.oclc.org/ooxml/spreadsheetml/main"

    static let declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
}

/// 数字写进文件的样子：最多 17 位有效数字（Double 的全部精度，Excel 读进去不丢东西），普通写法、不用科学计数法。
/// 读回来核对时两边都过一遍它（SaveVerifier）。
enum XLSXNumber {
    static func text(_ value: Decimal) -> String {
        DecimalMath.plainString(DecimalMath.roundSignificant(value, digits: 17))
    }

    /// 列宽、行高、字号这类小数：整数不带 ".0"，其余用能原样读回来的最短写法。
    static func text(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : "\(value)"
    }
}

/// 共用字符串表：原文件里已有的文字复用原来的编号（富文本那几条不复用，免得把格式带到别的格子），新文字往后加。
/// 已有的编号一个不动（设计 7.2 节）。
struct SharedStringTable {
    private(set) var appended: [String] = []
    private var indices: [String: Int] = [:]
    private let existing: [String]

    init(existing: [String] = [], rich: Set<Int> = []) {
        self.existing = existing
        for (index, text) in existing.enumerated() where !rich.contains(index) && indices[text] == nil {
            indices[text] = index
        }
    }

    /// `original` 是这一格在原文件里用的那条（富文本）：文字没变就接着用它，格式留着。
    mutating func index(of text: String, original: Int? = nil) -> Int {
        if let original, existing.indices.contains(original), existing[original] == text { return original }
        if let known = indices[text] { return known }
        let index = existing.count + appended.count
        appended.append(text)
        indices[text] = index
        return index
    }

    /// 一条 `<si>`。
    static func item(_ text: String, prefix: String) -> String {
        "<\(prefix)si><\(prefix)t xml:space=\"preserve\">\(XMLText.text(text))</\(prefix)t></\(prefix)si>"
    }
}

extension Sheet {
    /// 写进 sheet 部件里的内容一样不一样（名字、隐藏、角色写在 workbook.xml 和别处，不算）。
    /// 一样就整个部件原字节照抄（设计 7.2 节）。
    func hasSameContent(as other: Sheet) -> Bool {
        cells == other.cells && columns == other.columns && rowFormats == other.rowFormats && frozen == other.frozen
            && merges == other.merges && tabColor == other.tabColor && defaultColumnWidth == other.defaultColumnWidth
            && defaultRowHeight == other.defaultRowHeight
    }
}
