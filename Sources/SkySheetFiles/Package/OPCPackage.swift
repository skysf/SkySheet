import Foundation
import SkyZip

/// xlsx 的包结构（Open Packaging Conventions）：zip 里的每个文件是一个「部件」，部件之间靠 `_rels/*.rels` 里的关系连起来。
/// 部件名统一不带开头的 "/"，如 `xl/worksheets/sheet1.xml`。
struct OPCPackage: Sendable {
    let zip: ZipArchive
    /// OPC 规定部件名不分大小写；zip 里是区分的。先精确找，找不到再不分大小写找。
    private let lowercasedNames: [String: String]

    init(data: Data) throws(XLSXError) {
        do {
            zip = try ZipArchive(data: data)
        } catch ZipError.notAZip {
            throw Self.classifyNonZip(data)
        } catch {
            throw XLSXError.zip(error)
        }
        var names: [String: String] = [:]
        for entry in zip.entries where !entry.isDirectory {
            names[entry.name.lowercased()] = names[entry.name.lowercased()] ?? entry.name
        }
        lowercasedNames = names
    }

    func has(_ part: String) -> Bool {
        zipName(for: part) != nil
    }

    func data(_ part: String) throws(XLSXError) -> Data {
        guard let name = zipName(for: part), let entry = zip.entry(named: name) else {
            throw XLSXError.missingPart(part)
        }
        do {
            return try zip.contents(of: entry)
        } catch {
            throw XLSXError.zip(error)
        }
    }

    /// 一个部件发出的关系。`part` 传 "" 表示包本身（`_rels/.rels`）。没有关系文件就是空的。
    func relationships(of part: String) throws(XLSXError) -> [Relationship] {
        let relsPart = Self.relationshipsPart(for: part)
        guard has(relsPart) else { return [] }
        let collector = RelationshipCollector(source: part)
        try XMLScanner.scan(try data(relsPart), part: relsPart, handler: collector)
        return collector.relationships
    }

    /// `xl/workbook.xml` → `xl/_rels/workbook.xml.rels`；包本身 → `_rels/.rels`。
    static func relationshipsPart(for part: String) -> String {
        guard let slash = part.lastIndex(of: "/") else { return "_rels/\(part).rels" }
        return "\(part[..<slash])/_rels/\(part[part.index(after: slash)...]).rels"
    }

    /// 把关系里的目标换成部件名：相对目标按来源部件所在的目录解析（处理 `..`），以 "/" 开头的是从包根算起。
    static func resolve(_ target: String, from sourcePart: String) -> String {
        let decoded = target.removingPercentEncoding ?? target
        var segments: [Substring]
        if decoded.hasPrefix("/") {
            segments = []
        } else {
            segments = sourcePart.split(separator: "/")
            if !segments.isEmpty { segments.removeLast() }   // 去掉来源部件自己的文件名
        }
        for segment in decoded.split(separator: "/") {
            switch segment {
            case ".": continue
            case "..": if !segments.isEmpty { segments.removeLast() }
            default: segments.append(segment)
            }
        }
        return segments.joined(separator: "/")
    }

    private func zipName(for part: String) -> String? {
        if zip.entry(named: part) != nil { return part }
        return lowercasedNames[part.lowercased()]
    }

    /// 不是 zip 的时候，看看是不是 OLE 文件（D0 CF 11 E0 开头）：有密码的 xlsx 里有一个叫 EncryptedPackage 的流，
    /// 否则多半是老的 .xls。
    private static func classifyNonZip(_ data: Data) -> XLSXError {
        let oleSignature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
        guard data.starts(with: oleSignature) else { return .zip(.notAZip) }
        let marker = Data("EncryptedPackage".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        return data.range(of: marker) != nil ? .passwordProtected : .legacyExcelFormat
    }
}

struct Relationship: Equatable, Sendable {
    let id: String
    let type: String
    /// 已经解析成部件名（外部链接保留原文）。
    let target: String
    let isExternal: Bool

    /// 关系类型按结尾认：过渡版的 `…/officeDocument/2006/relationships/worksheet` 和严格版的
    /// `http://purl.oclc.org/ooxml/officeDocument/relationships/worksheet` 都要认。
    func hasType(_ name: String) -> Bool {
        type.hasSuffix("/" + name)
    }
}

private final class RelationshipCollector: XMLScanHandler {
    let source: String
    var relationships: [Relationship] = []

    init(source: String) {
        self.source = source
    }

    func start(_ element: String, attributes: [String: String]) {
        guard element == "Relationship", let id = attributes["Id"], let target = attributes["Target"] else { return }
        let external = attributes["TargetMode"] == "External"
        relationships.append(Relationship(
            id: id,
            type: attributes["Type"] ?? "",
            target: external ? target : OPCPackage.resolve(target, from: source),
            isExternal: external
        ))
    }

    func end(_ element: String, text: String) {}
}
