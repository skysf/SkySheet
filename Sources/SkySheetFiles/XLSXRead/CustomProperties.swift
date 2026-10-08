import Foundation
import SkySheetCore

/// 哪些是 AI 的 sheet、是谁写的：记在 `docProps/custom.xml`（设计 7.2 节、9.3 节第 2 条）。每张 AI 的 sheet 一个
/// 自定义属性 `SkySheet.AI.<sheetId>`，值是一小段 JSON 署名，不超过 255 个字符（Excel 界面里自定义属性的值最长这么多）。
/// 文件被别的软件另存过、属性丢了，这张 sheet 就当原始数据（第 3 条）：AI 只是要再复制一份，数据不会被改。
enum AIProperties {
    static let prefix = "SkySheet.AI."
    static let partName = "docProps/custom.xml"
    static let namespace = "http://schemas.openxmlformats.org/officeDocument/2006/custom-properties"
    static let typesNamespace = "http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"
    static let relationshipType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/custom-properties"
    static let contentType = "application/vnd.openxmlformats-officedocument.custom-properties+xml"
    /// 自定义属性统一用的那个 fmtid（Office 的「用户定义属性」）。
    static let formatID = "{D5CDD505-2E9C-101B-9397-08002B2CF9AE}"

    /// 工作簿里每张 AI 的 sheet 该写的属性：名字 → 值。
    static func properties(of workbook: Workbook) -> [String: String] {
        var result: [String: String] = [:]
        for sheet in workbook.sheets {
            if let authorship = sheet.role.authorship { result[prefix + String(sheet.id)] = encode(authorship) }
        }
        return result
    }

    // MARK: - 署名的写法

    /// 紧凑的 JSON：c / m / t 是谁建的（客户端、模型、时间），l / lm / lt 是最后谁改的；cu、lu 为 1 表示是用户自己。
    /// 时间精确到秒。名字太长就截短，保证整段不超过 255 个字符。
    static func encode(_ authorship: AIAuthorship) -> String {
        var object: [String: Any] = [:]
        func put(_ mark: AIAuthorship.Mark, client: String, model: String, time: String, user: String) {
            switch mark.author {
            case .user:
                object[user] = 1
            case .ai(let name, let modelName):
                object[client] = String(name.prefix(30))
                if let modelName { object[model] = String(modelName.prefix(40)) }
            }
            object[time] = timestamp.string(from: mark.date)
        }
        put(authorship.created, client: "c", model: "m", time: "t", user: "cu")
        if let last = authorship.lastChanged { put(last, client: "l", model: "lm", time: "lt", user: "lu") }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ text: String) -> AIAuthorship? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return nil }
        func mark(client: String, model: String, time: String, user: String) -> AIAuthorship.Mark? {
            guard let date = (object[time] as? String).flatMap(timestamp.date(from:)) else { return nil }
            if (object[user] as? Int) == 1 { return AIAuthorship.Mark(.user, date: date) }
            guard let name = object[client] as? String else { return nil }
            return AIAuthorship.Mark(.ai(client: name, model: object[model] as? String), date: date)
        }
        guard let created = mark(client: "c", model: "m", time: "t", user: "cu") else { return nil }
        return AIAuthorship(created: created, lastChanged: mark(client: "l", model: "lm", time: "lt", user: "lu"))
    }

    /// 时间的写法：ISO 8601，精确到秒，UTC（2026-10-08T06:03:00Z）。
    private enum timestamp {
        static func string(from date: Date) -> String { date.formatted(.iso8601) }
        static func date(from text: String) -> Date? { try? Date(text, strategy: .iso8601) }
    }

    // MARK: - 部件

    /// 新建的 custom.xml。
    static func freshPart(_ properties: [String: String]) -> Data {
        Data((OOXML.declaration + "<Properties xmlns=\"\(namespace)\" xmlns:vt=\"\(typesNamespace)\">"
              + elements(properties, firstID: 2, prefix: "", typesPrefix: "vt:") + "</Properties>").utf8)
    }

    /// 在原来的 custom.xml 上换掉 SkySheet.AI.* 那几条，别的属性原样留着；新属性的 pid 接着最大的往后编。
    static func patchedPart(_ original: Data, properties: [String: String]) -> Data? {
        guard var document = XMLFragments(original) else { return nil }
        document.children.removeAll { child in
            child.name == "property" && (XMLFragments.attribute("name", in: child.raw) ?? "").hasPrefix(prefix)
        }
        let maxID = document.children.compactMap { XMLFragments.attribute("pid", in: $0.raw).flatMap { Int($0) } }.max() ?? 1
        let typesPrefix = document.prefix(forNamespace: typesNamespace) ?? "vt:"
        var rootStart = document.rootStart
        if document.prefix(forNamespace: typesNamespace) == nil {
            rootStart = XMLFragments.settingAttribute("xmlns:vt", to: typesNamespace, in: rootStart)
        }
        document.rootStart = rootStart
        let added = elements(properties, firstID: maxID + 1, prefix: document.prefix, typesPrefix: typesPrefix)
        if !added.isEmpty { document.children.append(XMLFragments.Child(name: "property", raw: added)) }
        return document.serialized()
    }

    private static func elements(_ properties: [String: String], firstID: Int, prefix p: String, typesPrefix t: String) -> String {
        properties.keys.sorted { (Int($0.dropFirst(Self.prefix.count)) ?? 0) < (Int($1.dropFirst(Self.prefix.count)) ?? 0) }
            .enumerated().map { offset, name in
                "<\(p)property fmtid=\"\(formatID)\" pid=\"\(firstID + offset)\" name=\"\(XMLText.attribute(name))\">"
                    + "<\(t)lpwstr>\(XMLText.text(properties[name] ?? ""))</\(t)lpwstr></\(p)property>"
            }.joined()
    }
}

/// 读 custom.xml：属性名 → 文字值（只要文字类型的；SkySheet 只用得到 SkySheet.AI.*）。
final class CustomPropertiesPart: XMLScanHandler {
    private(set) var values: [String: String] = [:]
    private var current: String?

    func start(_ element: String, attributes: [String: String]) {
        if element == "property" { current = attributes["name"] }
    }

    func end(_ element: String, text: String) {
        switch element {
        case "lpwstr", "lpstr", "bstr":
            if let current { values[current] = XMLText.decodeEscapes(text) }
        case "property":
            current = nil
        default:
            break
        }
    }
}
