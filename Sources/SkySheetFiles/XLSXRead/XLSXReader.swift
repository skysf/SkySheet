import Foundation
import SkySheetCore

/// 读 xlsx，得到 SkySheetCore 的工作簿模型（设计 7.1 节）。读进来的公式都是 `.pending`：
/// 显示文件里的缓存值，调用方决定什么时候重算（`Recalculator`）。
///
/// 第一版只读格子、公式、样式（数字格式、字体、填充、边框、主题色）和几样版面信息。图片、批注、条件格式这些读不懂的部件 M3 写文件时原样保留，
/// 这里不碰。图表 sheet、对话框 sheet 不是表格，跳过。
public enum XLSXReader {
    public static func read(contentsOf url: URL) throws -> Workbook {
        try read(Data(contentsOf: url))
    }

    public static func read(_ data: Data) throws(XLSXError) -> Workbook {
        let package = try OPCPackage(data: data)
        let workbookPath = try workbookPartName(in: package)
        let workbookPart = WorkbookPart()
        try XMLScanner.scan(try package.data(workbookPath), part: workbookPath, handler: workbookPart)

        let relationships = try package.relationships(of: workbookPath)
        let styles = StylesPart()
        if let path = relationships.first(where: { $0.hasType("styles") })?.target, package.has(path) {
            try XMLScanner.scan(try package.data(path), part: path, handler: styles)
        }
        let strings = SharedStringsPart()
        if let path = relationships.first(where: { $0.hasType("sharedStrings") })?.target, package.has(path) {
            try XMLScanner.scan(try package.data(path), part: path, handler: strings)
        }
        let theme = ThemePart()
        if let path = relationships.first(where: { $0.hasType("theme") })?.target, package.has(path) {
            try XMLScanner.scan(try package.data(path), part: path, handler: theme)
        }

        var sheets: [Sheet] = []
        for entry in workbookPart.sheets {
            guard let relationship = relationships.first(where: { $0.id == entry.relationshipID }),
                  relationship.hasType("worksheet") else { continue }
            var sheet = Sheet(id: entry.sheetID, name: entry.name)
            sheet.visibility = entry.visibility
            let part = WorksheetPart(sheet: sheet, sharedStrings: strings.strings, dateSystem: workbookPart.dateSystem)
            try XMLScanner.scan(try package.data(relationship.target), part: relationship.target, handler: part)
            sheets.append(part.sheet)
        }

        let styleTable = StyleTable(customNumberFormats: styles.numberFormats,
                                    cellFormats: styles.cellFormats.isEmpty ? [CellFormat()] : styles.cellFormats,
                                    fonts: styles.fonts, fills: styles.fills, borders: styles.borders)
        let names = workbookPart.definedNames.map { entry in
            DefinedName(name: entry.name, formula: entry.formula, sheetIndex: entry.sheetPosition)
        }
        return Workbook(sheets: sheets, styles: styleTable, dateSystem: workbookPart.dateSystem, definedNames: names,
                        themeColors: theme.colors ?? Workbook.defaultThemeColors)
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
