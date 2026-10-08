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
