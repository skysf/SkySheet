import Foundation
import SkySheetCore

/// xl/worksheets/sheetN.xml：格子、公式、列宽行高、冻结窗格、合并单元格、页签颜色。
///
/// 宽容处理（设计 7.1 节），腾讯文档的怪癖都在样例里：
/// - `<f>` 里的公式原文带开头的 "="：去掉。
/// - `<c t="s"/>` 没有 `<v>`：空格子（只带样式）。
/// - 格子、行没写 r：按顺序往后排。
/// - 共享公式（`<f t="shared" si="0">`，Excel 大量使用）：跟随者用 ReferenceShift 从主公式平移出来。
///   主公式切不了词、平移又会改它的，跟随者的公式算不出来，原文空着（ReferenceShift.isExact）。
/// - `<f>` 带着属性的（共享公式、数组公式、模拟运算表……）记下原样（StoredFormula），保存时没改过的照原样写回。
final class WorksheetPart: XMLScanHandler {
    private(set) var sheet: Sheet
    private(set) var storedFormulas: [CellAddress: StoredFormula] = [:]
    private let sharedStrings: [String]
    private let richIndices: Set<Int>
    private let dateSystem: DateSystem

    private var row = -1
    private var nextColumn = 0
    private var cell: PendingCell?
    private var inInlineString = false
    private var phoneticDepth = 0
    private var sharedMasters: [String: (address: CellAddress, source: String)] = [:]
    private var sharedFollowers: [(address: CellAddress, index: String)] = []
    /// 所有带 `t="shared"` 的格子和它们 `<f>` 上的属性：主格、跟随者都在里面，读完 sheetData 再记成 StoredFormula。
    private var sharedCells: [(address: CellAddress, index: String, follower: Bool, attributes: [String: String])] = []

    private struct PendingCell {
        let address: CellAddress
        let type: String?
        let style: Int
        var value: String?
        var formula: String?
        var formulaAttributes: [String: String]?
        var inlineText = ""
    }

    init(sheet: Sheet, sharedStrings: [String], richIndices: Set<Int> = [], dateSystem: DateSystem) {
        self.sheet = sheet
        self.sharedStrings = sharedStrings
        self.richIndices = richIndices
        self.dateSystem = dateSystem
    }

    func start(_ element: String, attributes: [String: String]) {
        switch element {
        case "row":
            row = attributes["r"].flatMap { Int($0) }.map { $0 - 1 } ?? row + 1
            nextColumn = 0
            let format = RowFormat(height: attributes["ht"].flatMap { Double($0) },
                                   hidden: isTrue(attributes["hidden"]),
                                   styleIndex: isTrue(attributes["customFormat"]) ? attributes["s"].flatMap { Int($0) } : nil)
            if format.height != nil || format.hidden || format.styleIndex != nil {
                sheet.rowFormats[row] = format
            }
        case "c":
            let address = attributes["r"].flatMap { CellAddress(a1: $0) } ?? CellAddress(row: max(row, 0), column: nextColumn)
            nextColumn = address.column + 1
            cell = PendingCell(address: address, type: attributes["t"], style: attributes["s"].flatMap { Int($0) } ?? 0)
        case "f":
            cell?.formulaAttributes = attributes
        case "is":
            inInlineString = true
        case "rPh":
            phoneticDepth += 1
        case "col":
            guard let first = attributes["min"].flatMap({ Int($0) }), let last = attributes["max"].flatMap({ Int($0) }) else { return }
            sheet.columns.append(ColumnFormat(first: first - 1, last: last - 1, width: attributes["width"].flatMap { Double($0) },
                                              hidden: isTrue(attributes["hidden"]), styleIndex: attributes["style"].flatMap { Int($0) }))
        case "pane":
            if ["frozen", "frozenSplit"].contains(attributes["state"] ?? "") {
                sheet.frozen = FrozenPanes(rows: attributes["ySplit"].flatMap { Int(Double($0) ?? 0) } ?? 0,
                                           columns: attributes["xSplit"].flatMap { Int(Double($0) ?? 0) } ?? 0)
            }
        case "mergeCell":
            if let range = attributes["ref"].flatMap({ CellRange(a1: $0) }) { sheet.merges.append(range) }
        case "tabColor":
            sheet.tabColor = attributes["rgb"]
        case "sheetFormatPr":
            sheet.defaultRowHeight = attributes["defaultRowHeight"].flatMap { Double($0) }
            sheet.defaultColumnWidth = attributes["defaultColWidth"].flatMap { Double($0) }
        default:
            break
        }
    }

    func end(_ element: String, text: String) {
        switch element {
        case "v": cell?.value = text
        // 腾讯文档在 <f> 里写的公式带开头的 "="（标准里不带）。去掉，否则一个公式都解析不了（2026-10-08 对照测试抓到的）。
        case "f": cell?.formula = text.hasPrefix("=") ? String(text.dropFirst()) : text
        case "t" where inInlineString && phoneticDepth == 0: cell?.inlineText += XMLText.decodeEscapes(text)
        case "is": inInlineString = false
        case "rPh": phoneticDepth -= 1
        case "c": finishCell()
        case "sheetData": resolveSharedFormulas()
        default: break
        }
    }

    private func finishCell() {
        guard let pending = cell else { return }
        cell = nil
        let value = cellValue(pending)
        var formula: CellFormula?
        if let attributes = pending.formulaAttributes {
            let source = pending.formula ?? ""
            // 写回时只带没有前缀的属性：CT_CellFormula 的属性都没有前缀，带前缀的扩展属性写回去对不上命名空间。
            let plain = attributes.filter { !$0.key.contains(":") }
            switch attributes["t"] {
            case "shared":
                let index = attributes["si"] ?? ""
                if source.isEmpty {
                    sharedFollowers.append((pending.address, index))
                } else {
                    sharedMasters[index] = (pending.address, source)
                }
                sharedCells.append((pending.address, index, source.isEmpty, plain))
            case "array":
                formula = CellFormula(source: source, arrayRange: attributes["ref"].flatMap { CellRange(a1: $0) })
            default:
                break
            }
            if formula == nil {
                formula = CellFormula(source: source)
            }
            formula?.cachedValue = pending.value == nil && pending.type != "inlineStr" ? nil : value
            if attributes["t"] != "shared", !plain.isEmpty, let formula {
                storedFormulas[pending.address] = StoredFormula(attributes: plain, source: formula.source,
                                                                arrayRange: formula.arrayRange, shared: nil)
            }
        }
        guard value != .empty || formula != nil || pending.style != 0 else { return }
        sheet.cells[pending.address] = Cell(value: value, formula: formula, styleIndex: pending.style)
    }

    private func cellValue(_ pending: PendingCell) -> CellValue {
        switch pending.type {
        case "s":
            guard let index = pending.value.flatMap({ Int($0) }), sharedStrings.indices.contains(index) else { return .empty }
            if richIndices.contains(index) { sheet.richTextSources[pending.address] = index }
            return .text(sharedStrings[index])
        case "str":
            return .text(XMLText.decodeEscapes(pending.value ?? ""))
        case "inlineStr":
            return .text(pending.inlineText)
        case "b":
            return .bool(["1", "true"].contains(pending.value?.lowercased() ?? ""))
        case "e":
            return .error(CellError(code: pending.value ?? "#VALUE!"))
        case "d":
            return pending.value.flatMap(isoDate).map(CellValue.number) ?? .empty
        default:
            guard let text = pending.value else { return .empty }
            return DecimalMath.parse(text).map(CellValue.number) ?? .text(text)
        }
    }

    /// 共享公式的跟随者：主公式按相对位置平移（同一个 ReferenceShift）。找不到主公式的留空原文，重算时算「未重算」、显示缓存值。
    /// 主公式切不了词、平移又会改它的（`A1+SUM(Table1[Amount])`）也留空：以前拿主公式原文冒充，B2 读成指着 A1，改了别的格子
    /// 一保存就写成了引用错的公式（读文件排查第 2 条，2026-11-16）。这种跟随者保存时只能照原样写（XLSXWriter）。
    private func resolveSharedFormulas() {
        let exact = sharedMasters.mapValues { ReferenceShift.isExact($0.source) }
        for (address, index) in sharedFollowers {
            guard let master = sharedMasters[index], var cell = sheet.cells[address] else { continue }
            cell.formula?.source = exact[index] == true
                ? ReferenceShift.shift(master.source, rows: address.row - master.address.row,
                                       columns: address.column - master.address.column)
                : ""
            sheet.cells[address] = cell
        }
        for (address, index, follower, attributes) in sharedCells {
            guard let formula = sheet.cells[address]?.formula else { continue }
            let master = sharedMasters[index]?.address
            storedFormulas[address] = StoredFormula(
                attributes: attributes, source: formula.source, arrayRange: formula.arrayRange,
                shared: .init(group: index, master: master, follower: follower,
                              unknown: follower && master != nil && exact[index] != true))
        }
    }

    /// `t="d"` 的值是 ISO 8601 日期（很少见）：换成序列号，带时刻的加上小数。
    private func isoDate(_ text: String) -> Decimal? {
        let parts = text.split(separator: "T", maxSplits: 1)
        let ymd = parts[0].split(separator: "-").compactMap { Int($0) }
        guard ymd.count == 3 else { return nil }
        var serial = Decimal(DateSerial.serial(from: CivilDate(year: ymd[0], month: ymd[1], day: ymd[2]), system: dateSystem))
        if parts.count == 2 {
            let hms = parts[1].prefix(8).split(separator: ":").compactMap { Double($0) }
            if hms.count == 3, let fraction = DecimalMath.decimal((hms[0] * 3600 + hms[1] * 60 + hms[2]) / 86_400) {
                serial += fraction
            }
        }
        return serial
    }

    private func isTrue(_ text: String?) -> Bool {
        ["1", "true"].contains(text?.lowercased() ?? "")
    }
}
