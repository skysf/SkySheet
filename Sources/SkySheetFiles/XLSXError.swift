import Foundation
import SkyZip

/// 打不开 xlsx 的原因。界面上给用户看的话按这里的分类写。
public enum XLSXError: Error, Equatable, Sendable {
    /// 有密码的 xlsx：其实是一个加密的 OLE 文件，不是 zip。
    case passwordProtected
    /// 老的 .xls（Excel 97–2003 的二进制格式），也是 OLE 文件。第一版不支持（设计第十五节）。
    case legacyExcelFormat
    case zip(ZipError)
    /// 缺少必需的部件（比如 workbook.xml），或者关系指向一个不存在的部件。
    case missingPart(String)
    case malformedXML(part: String, line: Int, reason: String)
}
