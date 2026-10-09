import Foundation
import SkySheetCore
import SkyZip

/// 写好的 xlsx，加上核对要用的清单（SaveVerifier）。
public struct XLSXWriteResult: Sendable {
    public let data: Data
    /// 原字节照抄的条目（zip 里的名字）。核对时逐个比对。
    let copiedEntries: [String]
    /// 重新生成的 sheet（编号）。核对时逐格比对。
    let regeneratedSheets: Set<Int>
}

/// 写 xlsx（设计 7.2 节「认识的重写，其余原样」）。
public enum XLSXWriter {
    /// 有原包就在原包上改：没动过的部件原字节照抄，没改过的 sheet 原样写回。没有原包（csv 另存成 xlsx）就新建一个。
    /// `baseline` 是打开（或上次保存）时的工作簿，用来判断哪张 sheet 改过；不知道就传 nil，所有 sheet 都重新生成。
    public static func write(_ workbook: Workbook, source: XLSXSource?, baseline: Workbook?,
                             now: Date = Date()) throws(XLSXWriteError) -> XLSXWriteResult {
        guard let source else { return try FreshPackage.write(workbook, now: now) }
        return try PackagePatch(workbook: workbook, source: source, baseline: baseline).write()
    }
}

/// 在原包上改。
private struct PackagePatch {
    let workbook: Workbook
    let source: XLSXSource
    let baseline: Workbook?

    private var package: OPCPackage { source.package }

    func write() throws(XLSXWriteError) -> XLSXWriteResult {
        guard let workbookFragments = XMLFragments(try read(source.workbookPart)) else {
            throw XLSXWriteError.unreadablePart(source.workbookPart)
        }
        guard !workbookFragments.rootStart.contains(OOXML.strictMain) else { throw XLSXWriteError.strictFormat }
        let directory = source.workbookPart.contains("/")
            ? String(source.workbookPart[...source.workbookPart.lastIndex(of: "/")!]) : ""
        func relative(_ path: String) -> String { String(path.dropFirst(directory.count)) }

        var replaced: [String: Data] = [:]
        var added: [(name: String, data: Data)] = []
        var removed: Set<String> = []
        var takenNames = Set(package.zip.entries.map { $0.name.lowercased() })
        var takenIDs = source.relationshipIDs
        var newRelationships: [PackageIndex.NewRelationship] = []
        var newOverrides: [(part: String, type: String)] = []
        func addPart(_ base: String, type: String, content: String, data: Data) {
            let name = Self.unused(directory + base, ".xml", taken: &takenNames)
            added.append((name, data))
            newRelationships.append(.init(id: Self.unusedID(&takenIDs), type: type, target: relative(name)))
            newOverrides.append((name, content))
        }

        // 每张 sheet：没改过的照抄，改过的在原部件上重写，新的生成。
        let baselineSheets = Dictionary(baseline?.sheets.map { ($0.id, $0) } ?? [], uniquingKeysWith: { first, _ in first })
        var strings = SharedStringTable(existing: source.sharedStrings, rich: source.richStrings)
        var entries: [WorkbookWriter.Entry] = []
        var regenerated: Set<Int> = []
        var structureChanged = false
        for sheet in workbook.sheets {
            guard let part = source.sheets[sheet.id] else {
                let name = Self.unused(directory + "worksheets/sheet", ".xml", taken: &takenNames)
                let id = Self.unusedID(&takenIDs)
                added.append((name, WorksheetWriter.write(sheet, original: nil, baseline: nil,
                                                          defaultRowHeight: workbook.styles.defaultRowHeight, strings: &strings)))
                newRelationships.append(.init(id: id, type: OOXML.worksheetType, target: relative(name)))
                newOverrides.append((name, OOXML.worksheetContent))
                entries.append(.init(sheet: sheet, relationshipID: id))
                regenerated.insert(sheet.id)
                structureChanged = true
                continue
            }
            entries.append(.init(sheet: sheet, relationshipID: part.relationshipID))
            let old = baselineSheets[sheet.id]
            if let old, old.hasSameContent(as: sheet) { continue }
            guard let original = XMLFragments(try read(part.path)) else { throw XLSXWriteError.unreadablePart(part.path) }
            replaced[part.path.lowercased()] = WorksheetWriter.write(sheet, original: original, baseline: old,
                                                                     richCells: source.richCells[sheet.id] ?? [:],
                                                                     defaultRowHeight: workbook.styles.defaultRowHeight,
                                                                     strings: &strings)
            regenerated.insert(sheet.id)
        }
        // 删掉的 sheet：部件和它的关系文件不要了。它引用的图片、批注留在包里没人指着，Excel 不在意。
        let live = Set(workbook.sheets.map(\.id))
        var removedIDs: Set<String> = []
        for (id, part) in source.sheets where !live.contains(id) {
            removed.insert(part.path.lowercased())
            removed.insert(OPCPackage.relationshipsPart(for: part.path).lowercased())
            removedIDs.insert(part.relationshipID)
            structureChanged = true
        }

        // 重写过 sheet 就让别的软件打开时自己重算一遍，计算链（calcChain）作废（设计 7.2 节）。
        let recalculate = !regenerated.isEmpty || structureChanged
        var removedTypes: [String] = []
        if recalculate, let chain = source.calcChainPart {
            removed.insert(chain.lowercased())
            removedTypes.append("calcChain")
        }

        if !strings.appended.isEmpty {
            if let path = source.sharedStringsPart {
                replaced[path.lowercased()] = try Self.appendStrings(strings.appended, to: try read(path), part: path)
            } else {
                addPart("sharedStrings", type: OOXML.sharedStringsType, content: OOXML.sharedStringsContent,
                        data: FreshPackage.sharedStrings(strings.appended))
            }
        }
        if let path = source.stylesPart {
            if let data = try StylesWriter.patch(try read(path), file: source.fileStyles, current: workbook.styles) {
                replaced[path.lowercased()] = data
            }
        } else if recalculate || workbook.styles != baseline?.styles {
            addPart("styles", type: OOXML.stylesType, content: OOXML.stylesContent, data: StylesWriter.fresh(workbook.styles))
        }

        // AI 的 sheet 和署名（custom.xml）：和原文件里记的一样就不碰；不一样就换掉 SkySheet.AI.* 那几条，没有这个部件就新建。
        let properties = AIProperties.properties(of: workbook)
        if properties != source.aiProperties {
            if let part = source.customPropertiesPart {
                guard let data = AIProperties.patchedPart(try read(part), properties: properties) else {
                    throw XLSXWriteError.unreadablePart(part)
                }
                replaced[part.lowercased()] = data
            } else if !properties.isEmpty {
                var name = AIProperties.partName
                if takenNames.contains(name.lowercased()) {
                    name = Self.unused("docProps/custom", ".xml", taken: &takenNames)
                } else {
                    takenNames.insert(name.lowercased())
                }
                added.append((name, AIProperties.freshPart(properties)))
                newOverrides.append((name, AIProperties.contentType))
                let packageRelationships = "_rels/.rels"
                let taken = try Self.relationshipIDs(in: try read(packageRelationships))
                var ids = taken
                if let data = try PackageIndex.patchRelationships(
                    try read(packageRelationships), part: packageRelationships, removingIDs: [], removingTypes: [],
                    adding: [.init(id: Self.unusedID(&ids), type: AIProperties.relationshipType, target: name)]) {
                    replaced[packageRelationships] = data
                }
            }
        }

        if let data = try WorkbookWriter.patch(workbookFragments, part: source.workbookPart, entries: entries,
                                               workbook: workbook, baseline: baseline,
                                               existing: Set(source.sheets.keys), recalculate: recalculate) {
            replaced[source.workbookPart.lowercased()] = data
        }
        let relationshipsPart = OPCPackage.relationshipsPart(for: source.workbookPart)
        if let data = try PackageIndex.patchRelationships(try read(relationshipsPart), part: relationshipsPart,
                                                          removingIDs: removedIDs, removingTypes: removedTypes,
                                                          adding: newRelationships) {
            replaced[relationshipsPart.lowercased()] = data
        }
        if let data = try PackageIndex.patchContentTypes(try read(PackageIndex.contentTypesName), removing: removed,
                                                         adding: newOverrides) {
            replaced[PackageIndex.contentTypesName.lowercased()] = data
        }
        return try assemble(replaced: replaced, added: added, removed: removed, regenerated: regenerated)
    }

    /// 拼 zip：`[Content_Types].xml` 放第一个，其余按原包的顺序，新部件放最后。没动过的条目连压缩后的字节都照抄。
    private func assemble(replaced: [String: Data], added: [(name: String, data: Data)], removed: Set<String>,
                          regenerated: Set<Int>) throws(XLSXWriteError) -> XLSXWriteResult {
        let typesKey = PackageIndex.contentTypesName.lowercased()
        let entries = package.zip.entries.filter { $0.name.lowercased() == typesKey }
            + package.zip.entries.filter { $0.name.lowercased() != typesKey }
        var writer = ZipWriter()
        var copied: [String] = []
        do throws(ZipError) {
            for entry in entries where !removed.contains(entry.name.lowercased()) {
                if let data = replaced[entry.name.lowercased()] {
                    try writer.addFile(entry.name, contents: data, modified: entry.modified)
                } else {
                    try writer.addCopy(of: entry, compressed: try package.zip.compressedData(of: entry))
                    if !entry.isDirectory { copied.append(entry.name) }
                }
            }
            for part in added {
                try writer.addFile(part.name, contents: part.data)
            }
        } catch {
            throw XLSXWriteError.zip(error)
        }
        return XLSXWriteResult(data: writer.finished(), copiedEntries: copied, regeneratedSheets: regenerated)
    }

    private func read(_ part: String) throws(XLSXWriteError) -> Data {
        do {
            return try package.data(part)
        } catch {
            throw XLSXWriteError.unreadablePart(part)
        }
    }

    /// 一个关系文件里已经用掉的 id。
    private static func relationshipIDs(in data: Data) throws(XLSXWriteError) -> Set<String> {
        guard let document = XMLFragments(data) else { throw XLSXWriteError.unreadablePart("_rels/.rels") }
        return Set(document.children.compactMap { XMLFragments.attribute("Id", in: $0.raw) })
    }

    /// 共用字符串表后面追加几条（在 extLst 之前），uniqueCount 改成条数。count（全书引用了多少次）算不出来，去掉，它是可选的。
    private static func appendStrings(_ texts: [String], to data: Data, part: String) throws(XLSXWriteError) -> Data {
        guard var table = XMLFragments(data) else { throw XLSXWriteError.unreadablePart(part) }
        let items = texts.map { XMLFragments.Child(name: "si", raw: SharedStringTable.item($0, prefix: table.prefix)) }
        table.children.insert(contentsOf: items, at: table.children.firstIndex { $0.name == "extLst" } ?? table.children.count)
        let count = table.children.filter { $0.name == "si" }.count
        table.rootStart = XMLFragments.settingAttribute("uniqueCount", to: String(count), in: table.rootStart)
        table.rootStart = XMLFragments.settingAttribute("count", to: nil, in: table.rootStart)
        return table.serialized()
    }

    /// `xl/worksheets/sheet` + 没用过的编号 + `.xml`（部件名不分大小写）。
    private static func unused(_ base: String, _ suffix: String, taken: inout Set<String>) -> String {
        var number = 1
        while taken.contains((base + String(number) + suffix).lowercased()) { number += 1 }
        let name = base + String(number) + suffix
        taken.insert(name.lowercased())
        return name
    }

    private static func unusedID(_ taken: inout Set<String>) -> String {
        var number = 1
        while taken.contains("rIdSky\(number)") { number += 1 }
        taken.insert("rIdSky\(number)")
        return "rIdSky\(number)"
    }
}

/// 没有原包时新建一个完整的 xlsx。
enum FreshPackage {
    static func write(_ workbook: Workbook, now: Date) throws(XLSXWriteError) -> XLSXWriteResult {
        var strings = SharedStringTable()
        var parts: [(name: String, data: Data)] = []
        var entries: [WorkbookWriter.Entry] = []
        var relationships: [PackageIndex.NewRelationship] = []
        var overrides: [(part: String, type: String)] = [("xl/workbook.xml", OOXML.workbookContent)]
        for (index, sheet) in workbook.sheets.enumerated() {
            let name = "worksheets/sheet\(index + 1).xml"
            parts.append(("xl/" + name, WorksheetWriter.write(sheet, original: nil, baseline: nil,
                                                              defaultRowHeight: workbook.styles.defaultRowHeight,
                                                              strings: &strings)))
            entries.append(.init(sheet: sheet, relationshipID: "rId\(index + 1)"))
            relationships.append(.init(id: "rId\(index + 1)", type: OOXML.worksheetType, target: name))
            overrides.append(("xl/" + name, OOXML.worksheetContent))
        }
        parts.append(("xl/styles.xml", StylesWriter.fresh(workbook.styles)))
        relationships.append(.init(id: "rId\(workbook.sheets.count + 1)", type: OOXML.stylesType, target: "styles.xml"))
        overrides.append(("xl/styles.xml", OOXML.stylesContent))
        if !strings.appended.isEmpty {
            parts.append(("xl/sharedStrings.xml", sharedStrings(strings.appended)))
            relationships.append(.init(id: "rId\(workbook.sheets.count + 2)", type: OOXML.sharedStringsType,
                                       target: "sharedStrings.xml"))
            overrides.append(("xl/sharedStrings.xml", OOXML.sharedStringsContent))
        }
        overrides += [("docProps/core.xml", OOXML.coreContent), ("docProps/app.xml", OOXML.appContent)]

        var rootRelationships: [PackageIndex.NewRelationship] = [
            .init(id: "rId1", type: OOXML.officeDocumentType, target: "xl/workbook.xml"),
            .init(id: "rId2", type: OOXML.corePropertiesType, target: "docProps/core.xml"),
            .init(id: "rId3", type: OOXML.extendedPropertiesType, target: "docProps/app.xml"),
        ]
        let properties = AIProperties.properties(of: workbook)
        if !properties.isEmpty {
            parts.append((AIProperties.partName, AIProperties.freshPart(properties)))
            overrides.append((AIProperties.partName, AIProperties.contentType))
            rootRelationships.append(.init(id: "rId4", type: AIProperties.relationshipType, target: AIProperties.partName))
        }
        let packageRelationships = PackageIndex.freshRelationships(rootRelationships)
        let files: [(name: String, data: Data)] = [
            (PackageIndex.contentTypesName, PackageIndex.freshContentTypes(overrides)),
            ("_rels/.rels", packageRelationships),
            ("docProps/app.xml", appProperties()),
            ("docProps/core.xml", coreProperties(now)),
            ("xl/workbook.xml", WorkbookWriter.fresh(entries: entries, workbook: workbook)),
            ("xl/_rels/workbook.xml.rels", PackageIndex.freshRelationships(relationships)),
        ] + parts
        var writer = ZipWriter()
        do throws(ZipError) {
            for file in files {
                try writer.addFile(file.name, contents: file.data)
            }
        } catch {
            throw XLSXWriteError.zip(error)
        }
        return XLSXWriteResult(data: writer.finished(), copiedEntries: [], regeneratedSheets: Set(workbook.sheets.map(\.id)))
    }

    static func sharedStrings(_ texts: [String]) -> Data {
        Data((OOXML.declaration + "<sst xmlns=\"\(OOXML.main)\" uniqueCount=\"\(texts.count)\">"
              + texts.map { SharedStringTable.item($0, prefix: "") }.joined() + "</sst>").utf8)
    }

    private static func appProperties() -> Data {
        Data((OOXML.declaration + "<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\">"
              + "<Application>SkySheet</Application></Properties>").utf8)
    }

    /// 只写创建和修改时间，不写作者（不往文件里放用户的名字）。
    private static func coreProperties(_ now: Date) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: now)
        return Data((OOXML.declaration
            + "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\""
            + " xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\""
            + " xmlns:dcmitype=\"http://purl.org/dc/dcmitype/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">"
            + "<dcterms:created xsi:type=\"dcterms:W3CDTF\">\(stamp)</dcterms:created>"
            + "<dcterms:modified xsi:type=\"dcterms:W3CDTF\">\(stamp)</dcterms:modified></cp:coreProperties>").utf8)
    }
}
