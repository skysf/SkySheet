import Foundation

/// 为什么这张 sheet 不能插删行列（设计第 11 条：只在安全的表上允许）。
///
/// 保存时 sheet 里我们读不懂的元素原文照抄、别的部件原字节照抄（设计 7.2 节，硬规矩第 3 条）。其中有些东西按格子位置
/// 指着这张表：图片钉在第几行第几列、条件格式管着哪一块、图表画的是哪几格……插删行列以后格子挪了，它们还指着原来的位置，
/// 在 Excel、腾讯文档里打开就对不上了。所以这种表上一律不插删。原来就没有这些东西的表，以及 SkySheet 里新建、复制、
/// 从 csv 导进来的表（整份由我们写，复制出来的表不带这些东西），可以插删。
public enum StructureLock: Hashable, Sendable {
    /// 图片、形状、图表、控件（`drawing`、`oleObjects`、`controls`）。
    case pictures
    /// 批注（`legacyDrawing`）。
    case comments
    case conditionalFormatting
    /// 下拉列表、输入限制（`dataValidations`）。
    case dataValidation
    case hyperlinks
    /// 筛选、排序（`autoFilter`、`sortState`）。
    case filter
    /// Excel 的「表格」（`tableParts`）。
    case tables
    /// 别的读不懂、又可能按位置指着格子的东西：元素名或关系类型，如 `rowBreaks`、`extLst`、`pivotTable`。
    case otherContent(String)
    /// 文件里别的部件（图表、数据透视表、别的表的条件格式……）按名字指着这张表。带着那个部件的名字。
    case referencedElsewhere(String)

    /// 给 AI 看的一句英文（界面上的话由 App 自己写，要能翻译）。
    public var reason: String {
        switch self {
        case .pictures: "it has pictures or charts"
        case .comments: "it has comments"
        case .conditionalFormatting: "it has conditional formatting"
        case .dataValidation: "it has data validation (drop-down lists or input rules)"
        case .hyperlinks: "it has hyperlinks"
        case .filter: "it has a filter or sort"
        case .tables: "it has Excel tables"
        case .otherContent(let name): "it has content SkySheet keeps but does not understand (\(name))"
        case .referencedElsewhere(let part): "another part of the file (\(part)) points at its cells"
        }
    }
}

extension XLSXSource {
    /// 这张 sheet（按 sheetId）能不能插删行列：能就是 nil。不在原包里的（这次新建、复制、导入的）总是能。
    /// 要解压、扫一遍别的部件，App 按文档缓存结果（原包只在保存以后换）。
    public func structureLock(forSheet id: Int) -> StructureLock? {
        guard let part = sheets[id] else { return nil }
        guard let data = try? package.data(part.path), let document = XMLFragments(data) else {
            return .otherContent("unreadable sheet part")
        }
        for child in document.children {
            if let lock = Self.lock(forElement: child.name) { return lock }
        }
        // 只靠关系挂上来的东西（数据透视表放在这张表上，就只有一条关系、没有元素）也算。
        for relationship in (try? package.relationships(of: part.path)) ?? [] {
            let type = String(relationship.type.split(separator: "/").last ?? "")
            guard !Self.harmlessRelationships.contains(type) else { continue }
            return .otherContent(type)
        }
        return referenceElsewhere(to: part)
    }

    /// 我们自己管的、或者和格子位置无关的元素，可以放心插删。别的按种类说清楚是什么。
    private static func lock(forElement name: String) -> StructureLock? {
        switch name {
        case "sheetPr", "dimension", "sheetViews", "sheetFormatPr", "cols", "sheetData", "sheetCalcPr", "sheetProtection",
             "mergeCells", "phoneticPr", "printOptions", "pageMargins", "pageSetup", "headerFooter", "legacyDrawingHF",
             "drawingHF", "picture":
            return nil
        case "drawing", "oleObjects", "controls": return .pictures
        case "legacyDrawing": return .comments
        case "conditionalFormatting": return .conditionalFormatting
        case "dataValidations": return .dataValidation
        case "hyperlinks": return .hyperlinks
        case "autoFilter", "sortState": return .filter
        case "tableParts": return .tables
        default: return .otherContent(name)
        }
    }

    /// 关系里这些类型不指格子：打印机设置、页眉页脚和背景用的图。图片、批注、超链接的关系都配着上面的元素，元素已经拦下了。
    private static let harmlessRelationships: Set<String> = ["printerSettings", "image", "vmlDrawing", "drawing",
                                                             "comments", "hyperlink"]

    /// 文件里别的部件有没有按名字指着这张表：图表的 `<c:f>Loan!$B$2:$B$9</c:f>`、数据透视表缓存的 `sheet="Loan"`、
    /// 别的表的条件格式和数据验证里的 `Loan!A1`。公式和定义的名称我们自己会改，不算：别的表只看 sheetData 以外的元素，
    /// workbook.xml 不看。共用字符串、样式、主题、文档属性、关系文件里没有引用，也不看。宁可多拦，不可漏拦。
    private func referenceElsewhere(to part: SheetPart) -> StructureLock? {
        let quoted = "'" + part.name.replacingOccurrences(of: "'", with: "''") + "'!"
        let patterns = [part.name + "!", quoted, "sheet=\"" + part.name + "\""]
        let otherSheets = Set(sheets.values.map { $0.path.lowercased() })
        let skipped = Set([part.path, workbookPart, stylesPart, sharedStringsPart, calcChainPart, customPropertiesPart]
            .compactMap { $0?.lowercased() })
        for entry in package.zip.entries where !entry.isDirectory {
            let name = entry.name.lowercased()
            guard name.hasSuffix(".xml") || name.hasSuffix(".vml"), !skipped.contains(name),
                  !name.hasPrefix("docprops/"), !name.contains("/theme/"), name != "[content_types].xml",
                  let data = try? package.data(entry.name) else { continue }
            var text: String
            if otherSheets.contains(name) {
                guard let fragments = XMLFragments(data) else { return .referencedElsewhere(entry.name) }
                text = fragments.children.filter { $0.name != "sheetData" }.map(\.raw).joined()
            } else {
                text = String(decoding: data, as: UTF8.self)
            }
            text = XMLText.unescape(text)
            if patterns.contains(where: { text.range(of: $0, options: .caseInsensitive) != nil }) {
                return .referencedElsewhere(entry.name)
            }
        }
        return nil
    }
}
