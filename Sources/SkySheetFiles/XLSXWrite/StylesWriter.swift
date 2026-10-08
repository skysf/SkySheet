import Foundation
import SkySheetCore

/// xl/styles.xml（设计 7.2 节）：已有的样式编号一个都不动，新的只往后加。
/// 原文件里我们不认识的东西（条件格式用的 dxfs、单元格样式、自定义调色板……）原样留着。
enum StylesWriter {
    /// CT_Stylesheet 里子元素的先后。
    static let order = ["numFmts", "fonts", "fills", "borders", "cellStyleXfs", "cellXfs", "cellStyles", "dxfs",
                        "tableStyles", "colors", "extLst"]

    /// 在原来的样式表上追加。`file` 是原文件里实际有的样式（读进来时没补默认值的那份）。
    /// 什么都没加返回 nil：部件原字节照抄。
    static func patch(_ original: Data, file: StyleTable, current: StyleTable) throws(XLSXWriteError) -> Data? {
        let added = try additions(from: file, to: current)
        guard !added.isEmpty else { return nil }
        guard var document = XMLFragments(original) else { throw XLSXWriteError.unreadablePart("styles") }
        let p = document.prefix
        let hasCellStyleXfs = document.child("cellStyleXfs") != nil
        func append(_ name: String, _ items: [String]) throws(XLSXWriteError) {
            guard !items.isEmpty else { return }
            guard let list = XMLFragments.appending(items, to: document.child(name)?.raw, name: p + name) else {
                throw XLSXWriteError.unreadablePart("styles")
            }
            document.set(name, raw: list, order: order)
        }
        try append("numFmts", added.numberFormats.map { numberFormat($0.id, $0.code, p) })
        try append("fonts", added.fonts.map { font($0, p) })
        try append("fills", added.fills.map { fill($0, p) })
        try append("borders", added.borders.map { border($0, p) })
        try append("cellXfs", added.cellFormats.map { cellFormat($0, p, styleReference: hasCellStyleXfs) })
        return document.serialized()
    }

    /// 新建一份完整的样式表（csv 另存成 xlsx、原包里没有样式表）。
    static func fresh(_ styles: StyleTable) -> Data {
        let p = ""
        var xml = OOXML.declaration + "<styleSheet xmlns=\"\(OOXML.main)\">"
        let formats = styles.customNumberFormats.sorted { $0.key < $1.key }
        if !formats.isEmpty {
            xml += "<numFmts count=\"\(formats.count)\">" + formats.map { numberFormat($0.key, $0.value, p) }.joined()
                + "</numFmts>"
        }
        xml += "<fonts count=\"\(styles.fonts.count)\">" + styles.fonts.map { font($0, p) }.joined() + "</fonts>"
        xml += "<fills count=\"\(styles.fills.count)\">" + styles.fills.map { fill($0, p) }.joined() + "</fills>"
        xml += "<borders count=\"\(styles.borders.count)\">" + styles.borders.map { border($0, p) }.joined() + "</borders>"
        xml += "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>"
        xml += "<cellXfs count=\"\(styles.cellFormats.count)\">"
            + styles.cellFormats.map { cellFormat($0, p, styleReference: true) }.joined() + "</cellXfs>"
        xml += "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles>"
        return Data((xml + "</styleSheet>").utf8)
    }

    // MARK: - 新加了什么

    struct Additions {
        var numberFormats: [(id: Int, code: String)] = []
        var fonts: [FontStyle] = []
        var fills: [FillStyle] = []
        var borders: [BorderStyle] = []
        var cellFormats: [CellFormat] = []

        var isEmpty: Bool {
            numberFormats.isEmpty && fonts.isEmpty && fills.isEmpty && borders.isEmpty && cellFormats.isEmpty
        }
    }

    /// 现在的样式表比原文件多出来的部分。原有的每一项都必须原封不动（只许往后加）。
    static func additions(from file: StyleTable, to current: StyleTable) throws(XLSXWriteError) -> Additions {
        func tail<T: Equatable>(_ existing: [T], _ now: [T]) throws(XLSXWriteError) -> [T] {
            guard now.count >= existing.count, Array(now.prefix(existing.count)) == existing else {
                throw XLSXWriteError.existingStylesChanged
            }
            return Array(now.dropFirst(existing.count))
        }
        var added = Additions()
        for (id, code) in file.customNumberFormats where current.customNumberFormats[id] != code {
            throw XLSXWriteError.existingStylesChanged
        }
        added.numberFormats = current.customNumberFormats.filter { file.customNumberFormats[$0.key] == nil }
            .sorted { $0.key < $1.key }.map { (id: $0.key, code: $0.value) }
        added.fonts = try tail(file.fonts, current.fonts)
        added.fills = try tail(file.fills, current.fills)
        added.borders = try tail(file.borders, current.borders)
        added.cellFormats = try tail(file.cellFormats, current.cellFormats)
        return added
    }

    // MARK: - 一项一项

    private static func numberFormat(_ id: Int, _ code: String, _ p: String) -> String {
        "<\(p)numFmt numFmtId=\"\(id)\" formatCode=\"\(XMLText.attribute(code))\"/>"
    }

    private static func font(_ font: FontStyle, _ p: String) -> String {
        var xml = "<\(p)font>"
        func flag(_ name: String, _ value: Bool?) {
            if let value { xml += value ? "<\(p)\(name)/>" : "<\(p)\(name) val=\"0\"/>" }
        }
        flag("b", font.bold)
        flag("i", font.italic)
        flag("strike", font.strikethrough)
        if let underline = font.underline { xml += underline ? "<\(p)u/>" : "<\(p)u val=\"none\"/>" }
        if let size = font.size { xml += "<\(p)sz val=\"\(XLSXNumber.text(size))\"/>" }
        if let color = font.color { xml += self.color("color", color, p) }
        if let name = font.name { xml += "<\(p)name val=\"\(XMLText.attribute(name))\"/>" }
        return xml + "</\(p)font>"
    }

    private static func fill(_ fill: FillStyle, _ p: String) -> String {
        let pattern = "<\(p)patternFill patternType=\"\(XMLText.attribute(fill.pattern ?? "none"))\""
        let colors = (fill.foreground.map { color("fgColor", $0, p) } ?? "") + (fill.background.map { color("bgColor", $0, p) } ?? "")
        return "<\(p)fill>" + (colors.isEmpty ? pattern + "/>" : pattern + ">" + colors + "</\(p)patternFill>") + "</\(p)fill>"
    }

    private static func border(_ border: BorderStyle, _ p: String) -> String {
        func edge(_ name: String, _ edge: BorderEdge?) -> String {
            guard let edge else { return "<\(p)\(name)/>" }
            let start = "<\(p)\(name) style=\"\(XMLText.attribute(edge.style))\""
            return edge.color.map { start + ">" + color("color", $0, p) + "</\(p)\(name)>" } ?? start + "/>"
        }
        return "<\(p)border>" + edge("left", border.left) + edge("right", border.right) + edge("top", border.top)
            + edge("bottom", border.bottom) + "<\(p)diagonal/></\(p)border>"
    }

    /// 和 Excel 写的一样，用到了哪一项就标 applyXxx="1"（LibreOffice 看这几个属性）。
    private static func cellFormat(_ format: CellFormat, _ p: String, styleReference: Bool) -> String {
        var xml = "<\(p)xf numFmtId=\"\(format.numberFormatID)\" fontId=\"\(format.fontID)\" fillId=\"\(format.fillID)\""
            + " borderId=\"\(format.borderID)\"" + (styleReference ? " xfId=\"0\"" : "")
        if format.numberFormatID != 0 { xml += " applyNumberFormat=\"1\"" }
        if format.fontID != 0 { xml += " applyFont=\"1\"" }
        if format.fillID != 0 { xml += " applyFill=\"1\"" }
        if format.borderID != 0 { xml += " applyBorder=\"1\"" }
        var alignment = ""
        if let horizontal = format.horizontalAlignment { alignment += " horizontal=\"\(XMLText.attribute(horizontal))\"" }
        if let vertical = format.verticalAlignment { alignment += " vertical=\"\(XMLText.attribute(vertical))\"" }
        if format.wrapText { alignment += " wrapText=\"1\"" }
        guard !alignment.isEmpty else { return xml + "/>" }
        return xml + " applyAlignment=\"1\"><\(p)alignment\(alignment)/></\(p)xf>"
    }

    private static func color(_ element: String, _ color: StyleColor, _ p: String) -> String {
        var xml = "<\(p)\(element)"
        switch color.source {
        case .rgb(let rgb): xml += " rgb=\"\(XMLText.attribute(rgb))\""
        case .theme(let index): xml += " theme=\"\(index)\""
        case .indexed(let index): xml += " indexed=\"\(index)\""
        case .automatic: xml += " auto=\"1\""
        }
        if color.tint != 0 { xml += " tint=\"\(XLSXNumber.text(color.tint))\"" }
        return xml + "/>"
    }
}
