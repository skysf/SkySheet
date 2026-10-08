import Foundation

/// 包的目录：关系文件（`*.rels`）和 `[Content_Types].xml` 的增删（设计 7.2 节）。别的条目原文照抄。
enum PackageIndex {
    struct NewRelationship {
        let id: String
        let type: String
        let target: String
    }

    static let contentTypesName = "[Content_Types].xml"

    /// 在关系文件上删掉一些关系（按 id，或者按类型结尾，如 "calcChain"），加上一些。都不用动返回 nil。
    static func patchRelationships(_ original: Data, part: String, removingIDs ids: Set<String>,
                                   removingTypes types: [String], adding: [NewRelationship]) throws(XLSXWriteError) -> Data? {
        guard var document = XMLFragments(original) else { throw XLSXWriteError.unreadablePart(part) }
        let count = document.children.count
        document.children.removeAll { child in
            guard child.name == "Relationship" else { return false }
            if let id = XMLFragments.attribute("Id", in: child.raw), ids.contains(id) { return true }
            let type = XMLFragments.attribute("Type", in: child.raw) ?? ""
            return types.contains { type.hasSuffix("/" + $0) }
        }
        guard document.children.count != count || !adding.isEmpty else { return nil }
        document.children += adding.map { XMLFragments.Child(name: "Relationship", raw: relationship($0, document.prefix)) }
        return document.serialized()
    }

    static func freshRelationships(_ relationships: [NewRelationship]) -> Data {
        Data((OOXML.declaration + "<Relationships xmlns=\"\(OOXML.packageRelationships)\">"
              + relationships.map { relationship($0, "") }.joined() + "</Relationships>").utf8)
    }

    /// `[Content_Types].xml`：删掉一些部件的 Override（部件名不分大小写），给新部件加 Override。都不用动返回 nil。
    static func patchContentTypes(_ original: Data, removing parts: Set<String>,
                                  adding: [(part: String, type: String)]) throws(XLSXWriteError) -> Data? {
        guard var document = XMLFragments(original) else { throw XLSXWriteError.unreadablePart(contentTypesName) }
        let count = document.children.count
        document.children.removeAll { child in
            guard child.name == "Override", let name = XMLFragments.attribute("PartName", in: child.raw) else { return false }
            let part = name.hasPrefix("/") ? String(name.dropFirst()) : name
            return parts.contains((part.removingPercentEncoding ?? part).lowercased())
        }
        guard document.children.count != count || !adding.isEmpty else { return nil }
        document.children += adding.map { XMLFragments.Child(name: "Override", raw: override($0.part, $0.type, document.prefix)) }
        return document.serialized()
    }

    static func freshContentTypes(_ overrides: [(part: String, type: String)]) -> Data {
        Data((OOXML.declaration + "<Types xmlns=\"\(OOXML.contentTypes)\">"
              + "<Default Extension=\"rels\" ContentType=\"\(OOXML.relationshipsContent)\"/>"
              + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
              + overrides.map { override($0.part, $0.type, "") }.joined() + "</Types>").utf8)
    }

    private static func relationship(_ item: NewRelationship, _ p: String) -> String {
        "<\(p)Relationship Id=\"\(XMLText.attribute(item.id))\" Type=\"\(XMLText.attribute(item.type))\""
            + " Target=\"\(XMLText.attribute(item.target))\"/>"
    }

    private static func override(_ part: String, _ type: String, _ p: String) -> String {
        "<\(p)Override PartName=\"/\(XMLText.attribute(part))\" ContentType=\"\(XMLText.attribute(type))\"/>"
    }
}
