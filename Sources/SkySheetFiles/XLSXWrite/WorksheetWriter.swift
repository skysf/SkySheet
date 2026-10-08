import Foundation
import SkySheetCore

/// 生成一个 sheet 部件（设计 7.2 节）：只重写我们管的元素（sheetPr 里的页签颜色、dimension、sheetViews 里的冻结窗格、
/// cols、sheetData、mergeCells），原来的别的元素（条件格式、数据验证、页面设置、图片……）原文照抄，按 schema 顺序排好。
enum WorksheetWriter {
    /// CT_Worksheet 里子元素的先后（ECMA-376 第 1 部分 18.3.1.99）。
    static let order = ["sheetPr", "dimension", "sheetViews", "sheetFormatPr", "cols", "sheetData", "sheetCalcPr",
                        "sheetProtection", "protectedRanges", "scenarios", "autoFilter", "sortState", "dataConsolidate",
                        "customSheetViews", "mergeCells", "phoneticPr", "conditionalFormatting", "dataValidations",
                        "hyperlinks", "printOptions", "pageMargins", "pageSetup", "headerFooter", "rowBreaks", "colBreaks",
                        "customProperties", "cellWatches", "ignoredErrors", "smartTags", "drawing", "legacyDrawing",
                        "legacyDrawingHF", "drawingHF", "picture", "oleObjects", "controls", "webPublishItems",
                        "tableParts", "extLst"]

    /// `original` 是原来的部件（新 sheet 传 nil）；`baseline` 是打开时的样子：页签颜色、冻结窗格没变就不碰原文。
    /// `richCells` 是原来用了富文本的格子（见 XLSXSource.richCells）。`defaultRowHeight` 是 sheet 没写默认行高时
    /// 按工作簿默认字体算的那个（StyleTable.defaultRowHeight）。
    static func write(_ sheet: Sheet, original: XMLFragments?, baseline: Sheet?, richCells: [CellAddress: Int] = [:],
                      defaultRowHeight: Double, strings: inout SharedStringTable) -> Data {
        var document = original ?? XMLFragments(
            declaration: OOXML.declaration,
            rootStart: "<worksheet xmlns=\"\(OOXML.main)\" xmlns:r=\"\(OOXML.relationships)\">", rootName: "worksheet")
        let p = document.prefix
        if original == nil || sheet.tabColor != baseline?.tabColor {
            document.set("sheetPr", raw: sheetProperties(sheet.tabColor, original: document.child("sheetPr")?.raw, p), order: order)
        }
        document.set("dimension", raw: "<\(p)dimension ref=\"\(sheet.cells.usedRange?.a1 ?? "A1")\"/>", order: order)
        if original == nil || sheet.frozen != baseline?.frozen {
            document.set("sheetViews", raw: sheetViews(sheet.frozen, original: document.child("sheetViews")?.raw, p), order: order)
        }
        // 没有 sheetFormatPr 的补上（Excel 存的文件都有）：Quick Look 遇到首格不在 A 列的行，没有默认行高就画成一大片空白
        // （2026-10-08 用 qlmanage 对照时发现的）。
        let formatChanged = sheet.defaultRowHeight != baseline?.defaultRowHeight
            || sheet.defaultColumnWidth != baseline?.defaultColumnWidth
        if document.child("sheetFormatPr") == nil || formatChanged {
            document.set("sheetFormatPr", raw: sheetFormat(sheet, original: document.child("sheetFormatPr")?.raw,
                                                           fallbackHeight: defaultRowHeight, p), order: order)
        }
        document.set("cols", raw: columns(sheet.columns, p), order: order)
        document.set("sheetData", raw: sheetData(sheet, p, richCells, &strings), order: order)
        document.set("mergeCells", raw: merges(sheet.merges, p), order: order)
        if original == nil {
            document.set("pageMargins", raw: "<\(p)pageMargins left=\"0.7\" right=\"0.7\" top=\"0.75\" bottom=\"0.75\" "
                         + "header=\"0.3\" footer=\"0.3\"/>", order: order)
        }
        return document.serialized()
    }

    // MARK: - 页签颜色、冻结窗格、列宽、合并单元格

    /// 原来有 sheetPr 就只换里面的 tabColor（它必须是第一个子元素），别的原样。
    private static func sheetProperties(_ tabColor: String?, original: String?, _ p: String) -> String? {
        let color = tabColor.map { "<\(p)tabColor rgb=\"\(XMLText.attribute($0))\"/>" } ?? ""
        guard var raw = original else { return tabColor == nil ? nil : "<\(p)sheetPr>\(color)</\(p)sheetPr>" }
        raw = raw.replacingOccurrences(of: "<(\\w+:)?tabColor\\b[^>]*/>", with: "", options: .regularExpression)
        if raw.hasSuffix("/>") {
            raw = String(raw.dropLast(2)) + ">" + "</\(XMLFragments.qualifiedName(raw))>"
        }
        guard let startEnd = raw.firstIndex(of: ">") else { return raw }
        raw.insert(contentsOf: color, at: raw.index(after: startEnd))
        return raw
    }

    /// 冻结窗格。原来有 sheetView 就只换里面的 pane（连带去掉 selection：它指向的窗格可能不在了，Excel 会重建），别的属性原样。
    private static func sheetViews(_ frozen: FrozenPanes?, original: String?, _ p: String) -> String {
        var pane = ""
        if let frozen, frozen.rows > 0 || frozen.columns > 0 {
            let topLeft = CellAddress(row: frozen.rows, column: frozen.columns).a1
            let active = frozen.rows > 0 && frozen.columns > 0 ? "bottomRight" : (frozen.rows > 0 ? "bottomLeft" : "topRight")
            pane = "<\(p)pane" + (frozen.columns > 0 ? " xSplit=\"\(frozen.columns)\"" : "")
                + (frozen.rows > 0 ? " ySplit=\"\(frozen.rows)\"" : "")
                + " topLeftCell=\"\(topLeft)\" activePane=\"\(active)\" state=\"frozen\"/>"
        }
        guard var raw = original,
              let viewRange = raw.range(of: "<(\\w+:)?sheetView\\b[^>]*>", options: .regularExpression) else {
            return "<\(p)sheetViews><\(p)sheetView workbookViewId=\"0\">\(pane)</\(p)sheetView></\(p)sheetViews>"
        }
        var viewStart = String(raw[viewRange])
        var closing = ""
        if viewStart.hasSuffix("/>") {
            closing = "</\(XMLFragments.qualifiedName(viewStart))>"
            viewStart = String(viewStart.dropLast(2)) + ">"
        }
        raw.replaceSubrange(viewRange, with: viewStart + pane + closing)
        // 只去掉原来的 pane 和 selection，刚插进去的那个 pane 在 viewStart 后面紧挨着，先保护起来。
        let marker = "\u{0}SKYPANE\u{0}"
        raw = raw.replacingOccurrences(of: viewStart + pane, with: viewStart + marker)
        raw = raw.replacingOccurrences(of: "<(\\w+:)?(pane|selection)\\b[^>]*/>", with: "", options: .regularExpression)
        return raw.replacingOccurrences(of: marker, with: pane)
    }

    /// 默认行高、列宽。defaultRowHeight 是必填的属性：sheet 没写就用按默认字体算的那个。
    private static func sheetFormat(_ sheet: Sheet, original: String?, fallbackHeight: Double, _ p: String) -> String {
        guard var raw = original else {
            return "<\(p)sheetFormatPr defaultRowHeight=\"\(XLSXNumber.text(sheet.defaultRowHeight ?? fallbackHeight))\""
                + (sheet.defaultColumnWidth.map { " defaultColWidth=\"\(XLSXNumber.text($0))\"" } ?? "") + "/>"
        }
        if let height = sheet.defaultRowHeight {
            raw = XMLFragments.settingAttribute("defaultRowHeight", to: XLSXNumber.text(height), in: raw)
        }
        return XMLFragments.settingAttribute("defaultColWidth", to: sheet.defaultColumnWidth.map(XLSXNumber.text), in: raw)
    }

    /// 列。原来没写宽度的（只设了样式或隐藏的列）照样不写：写了就把「跟随默认宽度」变成了固定宽度。
    private static func columns(_ columns: [ColumnFormat], _ p: String) -> String? {
        guard !columns.isEmpty else { return nil }
        let items = columns.sorted { $0.first < $1.first }.map { column -> String in
            var item = "<\(p)col min=\"\(column.first + 1)\" max=\"\(column.last + 1)\""
            if let width = column.width { item += " width=\"\(XLSXNumber.text(width))\" customWidth=\"1\"" }
            if column.hidden { item += " hidden=\"1\"" }
            if let style = column.styleIndex { item += " style=\"\(style)\"" }
            return item + "/>"
        }
        return "<\(p)cols>\(items.joined())</\(p)cols>"
    }

    private static func merges(_ merges: [CellRange], _ p: String) -> String? {
        guard !merges.isEmpty else { return nil }
        return "<\(p)mergeCells count=\"\(merges.count)\">"
            + merges.map { "<\(p)mergeCell ref=\"\($0.a1)\"/>" }.joined() + "</\(p)mergeCells>"
    }

    // MARK: - 格子

    private static func sheetData(_ sheet: Sheet, _ p: String, _ richCells: [CellAddress: Int],
                                  _ strings: inout SharedStringTable) -> String {
        var xml = "<\(p)sheetData>"
        let rows = Set(sheet.cells.rowIndices).union(sheet.rowFormats.keys).sorted()
        for row in rows {
            var attributes = "r=\"\(row + 1)\""
            if let format = sheet.rowFormats[row] {
                if let height = format.height { attributes += " ht=\"\(XLSXNumber.text(height))\" customHeight=\"1\"" }
                if format.hidden { attributes += " hidden=\"1\"" }
                if let style = format.styleIndex { attributes += " s=\"\(style)\" customFormat=\"1\"" }
            }
            let cells = sheet.cells.row(row)
            guard !cells.isEmpty else {
                xml += "<\(p)row \(attributes)/>"
                continue
            }
            xml += "<\(p)row \(attributes)>"
            for (column, cell) in cells {
                let address = CellAddress(row: row, column: column)
                xml += cellXML(cell, at: address, p, richCells[address], &strings)
            }
            xml += "</\(p)row>"
        }
        return xml + "</\(p)sheetData>"
    }

    /// 一个格子。公式写成 Excel 的标准写法（不带 "="、新函数加 _xlfn.），后面跟着算出来的值（别的软件打开时先显示它）。
    /// 循环引用的格子不写值（设计 5.5 节）。
    private static func cellXML(_ cell: Cell, at address: CellAddress, _ p: String, _ richIndex: Int?,
                                _ strings: inout SharedStringTable) -> String {
        var attributes = "r=\"\(address.a1)\""
        if cell.styleIndex != 0 { attributes += " s=\"\(cell.styleIndex)\"" }
        var type: String?
        var inner = ""
        func value(_ text: String) { inner += "<\(p)v>\(text)</\(p)v>" }

        if let formula = cell.formula {
            let source = XMLText.formula(FormulaRewriter.storageForm(formula.source))
            if let range = formula.arrayRange {
                inner += "<\(p)f t=\"array\" ref=\"\(range.a1)\">\(source)</\(p)f>"
            } else {
                inner += "<\(p)f>\(source)</\(p)f>"
            }
            switch cell.value {
            case .number(let number): value(XLSXNumber.text(number))
            case .text(let text): type = "str"; value(XMLText.text(text))
            case .bool(let flag): type = "b"; value(flag ? "1" : "0")
            case .error(let error) where error != .circular: type = "e"; value(XMLText.text(error.code))
            case .error, .empty: break
            }
        } else {
            switch cell.value {
            case .empty: break
            case .number(let number): value(XLSXNumber.text(number))
            case .text(let text): type = "s"; value(String(strings.index(of: text, original: richIndex)))
            case .bool(let flag): type = "b"; value(flag ? "1" : "0")
            case .error(let error): type = "e"; value(XMLText.text(error.code))
            }
        }
        if let type { attributes += " t=\"\(type)\"" }
        return inner.isEmpty ? "<\(p)c \(attributes)/>" : "<\(p)c \(attributes)>\(inner)</\(p)c>"
    }
}
