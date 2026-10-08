import Foundation
import SkySheetCore

/// 读进来的 xlsx：工作簿模型，加上原来那个包。保存时没改过的部分从原包照抄（设计 7.2 节）。
public struct XLSXDocument: Sendable {
    public var workbook: Workbook
    public var source: XLSXSource
}

/// 原包的样子：zip 本身，以及哪个部件是什么。只有 XLSXWriter 用得到里面的东西。
public struct XLSXSource: Sendable {
    struct SheetPart: Sendable {
        let path: String
        let relationshipID: String
    }

    let package: OPCPackage
    let workbookPart: String
    /// sheetId → 它的部件和在 workbook 关系里的 id。
    let sheets: [Int: SheetPart]
    let stylesPart: String?
    /// 样式表里实际有的东西（没补默认值）。保存时比它多出来的才是新加的（设计 7.2 节）。
    let fileStyles: StyleTable
    let sharedStringsPart: String?
    let sharedStrings: [String]
    let richStrings: Set<Int>
    /// sheetId → 这张 sheet 里用了富文本共用字符串的格子和那条的编号。
    let richCells: [Int: [CellAddress: Int]]
    let calcChainPart: String?
    /// workbook 关系里已经用掉的 id：新加的不能撞上。
    let relationshipIDs: Set<String>
}

/// 读 xlsx，得到 SkySheetCore 的工作簿模型（设计 7.1 节）。读进来的公式都是 `.pending`：
/// 显示文件里的缓存值，调用方决定什么时候重算（`Recalculator`）。
///
/// 读格子、公式、样式（数字格式、字体、填充、边框、主题色）和几样版面信息。图片、批注、条件格式这些读不懂的部件不碰，
/// 保存时从原包照抄。图表 sheet、对话框 sheet 不是表格，跳过（保存时也原样留着）。
public enum XLSXReader {
    public static func read(contentsOf url: URL) throws -> Workbook {
        try read(Data(contentsOf: url))
    }

    public static func read(_ data: Data) throws(XLSXError) -> Workbook {
        try readDocument(data).workbook
    }

    public static func readDocument(_ data: Data) throws(XLSXError) -> XLSXDocument {
        let package = try OPCPackage(data: data)
        let workbookPath = try workbookPartName(in: package)
        let workbookPart = WorkbookPart()
        try XMLScanner.scan(try package.data(workbookPath), part: workbookPath, handler: workbookPart)

        let relationships = try package.relationships(of: workbookPath)
        func part(_ type: String) -> String? {
            relationships.first { $0.hasType(type) && !$0.isExternal }.map(\.target).flatMap { package.has($0) ? $0 : nil }
        }
        let styles = StylesPart()
        if let path = part("styles") {
            try XMLScanner.scan(try package.data(path), part: path, handler: styles)
        }
        let strings = SharedStringsPart()
        if let path = part("sharedStrings") {
            try XMLScanner.scan(try package.data(path), part: path, handler: strings)
        }
        let theme = ThemePart()
        if let path = part("theme") {
            try XMLScanner.scan(try package.data(path), part: path, handler: theme)
        }

        var sheets: [Sheet] = []
        var sheetParts: [Int: XLSXSource.SheetPart] = [:]
        /// workbook.xml 里第几个 <sheet>（包括跳过的图表 sheet）→ 模型里第几张。定义名称的 localSheetId 按前者数。
        var modelIndex: [Int: Int] = [:]
        var richCells: [Int: [CellAddress: Int]] = [:]
        for (position, entry) in workbookPart.sheets.enumerated() {
            guard let relationship = relationships.first(where: { $0.id == entry.relationshipID }),
                  relationship.hasType("worksheet") else { continue }
            modelIndex[position] = sheets.count
            var sheet = Sheet(id: entry.sheetID, name: entry.name)
            sheet.visibility = entry.visibility
            let reader = WorksheetPart(sheet: sheet, sharedStrings: strings.strings, richIndices: strings.richIndices,
                                       dateSystem: workbookPart.dateSystem)
            try XMLScanner.scan(try package.data(relationship.target), part: relationship.target, handler: reader)
            sheets.append(reader.sheet)
            if !reader.richCells.isEmpty { richCells[entry.sheetID] = reader.richCells }
            sheetParts[entry.sheetID] = XLSXSource.SheetPart(path: relationship.target, relationshipID: entry.relationshipID)
        }

        // 模型里的样式表每一项至少有一个（缺的补新建工作簿的默认值），保存时补上的这几项算新加的。
        let fileStyles = StyleTable(customNumberFormats: styles.numberFormats, cellFormats: styles.cellFormats,
                                    fonts: styles.fonts, fills: styles.fills, borders: styles.borders)
        let defaults = StyleTable()
        let styleTable = StyleTable(customNumberFormats: styles.numberFormats,
                                    cellFormats: styles.cellFormats.isEmpty ? defaults.cellFormats : styles.cellFormats,
                                    fonts: styles.fonts.isEmpty ? defaults.fonts : styles.fonts,
                                    fills: styles.fills.isEmpty ? defaults.fills : styles.fills,
                                    borders: styles.borders.isEmpty ? defaults.borders : styles.borders)
        // 只在图表 sheet 里有效的名称没地方放，不读（第一版公式里也用不到定义的名称）。
        let names = workbookPart.definedNames.compactMap { entry -> DefinedName? in
            let scope = entry.sheetPosition.map { modelIndex[$0] }
            if case .some(.none) = scope { return nil }
            return DefinedName(name: entry.name, formula: entry.formula, sheetIndex: scope ?? nil,
                               extraAttributes: entry.extraAttributes)
        }
        let workbook = Workbook(sheets: sheets, styles: styleTable, dateSystem: workbookPart.dateSystem,
                                definedNames: names, themeColors: theme.colors ?? Workbook.defaultThemeColors,
                                nextSheetID: (workbookPart.sheets.map(\.sheetID).max() ?? 0) + 1)
        let source = XLSXSource(package: package, workbookPart: workbookPath, sheets: sheetParts,
                                stylesPart: part("styles"), fileStyles: fileStyles, sharedStringsPart: part("sharedStrings"),
                                sharedStrings: strings.strings, richStrings: strings.richIndices, richCells: richCells,
                                calcChainPart: part("calcChain"), relationshipIDs: Set(relationships.map(\.id)))
        return XLSXDocument(workbook: workbook, source: source)
    }

    /// 包的根关系里 officeDocument 指向的部件；没写关系的不规范文件退到约定的 xl/workbook.xml。
    private static func workbookPartName(in package: OPCPackage) throws(XLSXError) -> String {
        if let target = try package.relationships(of: "").first(where: { $0.hasType("officeDocument") })?.target,
           package.has(target) {
            return target
        }
        guard package.has("xl/workbook.xml") else { throw XLSXError.missingPart("xl/workbook.xml") }
        return "xl/workbook.xml"
    }
}
