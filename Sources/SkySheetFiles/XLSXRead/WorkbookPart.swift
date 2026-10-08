import Foundation
import SkySheetCore

/// xl/workbook.xml：有哪些 sheet（名字、编号、关系 id）、日期系统、定义的名称。
final class WorkbookPart: XMLScanHandler {
    struct SheetEntry {
        let name: String
        let sheetID: Int
        let relationshipID: String
        let visibility: SheetVisibility
    }

    struct NameEntry {
        let name: String
        let sheetPosition: Int?
        let formula: String
    }

    private(set) var sheets: [SheetEntry] = []
    private(set) var definedNames: [NameEntry] = []
    private(set) var dateSystem: DateSystem = .from1900
    private var pendingName: (name: String, sheetPosition: Int?)?

    func start(_ element: String, attributes: [String: String]) {
        switch element {
        case "sheet":
            guard let name = attributes["name"], let id = attributes["id"] else { return }
            let visibility: SheetVisibility = switch attributes["state"] {
            case "hidden": .hidden
            case "veryHidden": .veryHidden
            default: .visible
            }
            sheets.append(SheetEntry(name: name, sheetID: Int(attributes["sheetId"] ?? "") ?? sheets.count + 1,
                                     relationshipID: id, visibility: visibility))
        case "workbookPr":
            dateSystem = ["1", "true"].contains(attributes["date1904"]?.lowercased() ?? "") ? .from1904 : .from1900
        case "definedName":
            if let name = attributes["name"] {
                pendingName = (name, attributes["localSheetId"].flatMap { Int($0) })
            }
        default:
            break
        }
    }

    func end(_ element: String, text: String) {
        if element == "definedName", let pending = pendingName {
            definedNames.append(NameEntry(name: pending.name, sheetPosition: pending.sheetPosition, formula: text))
            pendingName = nil
        }
    }
}

/// xl/styles.xml：自定义数字格式和 `<cellXfs>`。字体、填充、边框的细节 M2 画表格时再读。
final class StylesPart: XMLScanHandler {
    private(set) var numberFormats: [Int: String] = [:]
    private(set) var cellFormats: [CellFormat] = []
    private var inCellFormats = false
    private var current: CellFormat?

    func start(_ element: String, attributes: [String: String]) {
        switch element {
        case "numFmt":
            if let id = attributes["numFmtId"].flatMap({ Int($0) }), let code = attributes["formatCode"] {
                numberFormats[id] = code
            }
        case "cellXfs":
            inCellFormats = true
        case "xf" where inCellFormats:
            // <cellStyleXfs> 里也有 <xf>，只认 <cellXfs> 里的：单元格的 s 属性指的是它们。
            current = CellFormat(numberFormatID: int(attributes["numFmtId"]), fontID: int(attributes["fontId"]),
                                 fillID: int(attributes["fillId"]), borderID: int(attributes["borderId"]))
        case "alignment" where current != nil:
            current?.horizontalAlignment = attributes["horizontal"]
            current?.verticalAlignment = attributes["vertical"]
            current?.wrapText = ["1", "true"].contains(attributes["wrapText"] ?? "")
        default:
            break
        }
    }

    func end(_ element: String, text: String) {
        switch element {
        case "xf" where inCellFormats:
            if let current { cellFormats.append(current) }
            current = nil
        case "cellXfs":
            inCellFormats = false
        default:
            break
        }
    }

    private func int(_ text: String?) -> Int {
        text.flatMap { Int($0) } ?? 0
    }
}

/// xl/sharedStrings.xml：所有 sheet 共用的文字表，格子里 t="s" 的值是它的下标。
/// 富文本（`<r><t>`）拼成纯文字；注音（`<rPh>`，日文假名标注）里的 `<t>` 不算正文。
final class SharedStringsPart: XMLScanHandler {
    private(set) var strings: [String] = []
    private var current: String?
    private var phoneticDepth = 0

    func start(_ element: String, attributes: [String: String]) {
        switch element {
        case "si": current = ""
        case "rPh": phoneticDepth += 1
        default: break
        }
    }

    func end(_ element: String, text: String) {
        switch element {
        case "t" where phoneticDepth == 0: current? += text
        case "rPh": phoneticDepth -= 1
        case "si":
            strings.append(current ?? "")
            current = nil
        default: break
        }
    }
}
