import Foundation
import SkySheetCore

public enum CSVWriteError: Error, Equatable, Sendable {
    /// 这个字符在文件原来的编码里写不出来（比如 GBK 的文件里新加了 emoji）。可以另存成 UTF-8 或 xlsx。
    case unencodableCharacter(Character)
    /// 写出来的文件解回来和要写的对不上（第三道保险）。
    case verificationFailed(String)
}

/// 写好的 csv，加上核对要用的字段表。
public struct CSVWriteResult: Sendable {
    public let data: Data
    let fields: [[String]]
    let format: CSVFormat
}

/// 写 csv（设计 7.3 节）：用读进来时的编码、BOM、分隔符、换行写回。csv 只有文字：
/// 数字写原值（最多 15 位有效数字，和读的时候认数字的规矩一致），日期写 yyyy-mm-dd，百分比写 5%，
/// 公式写算出来的结果（csv 存不了公式），循环引用的格子留空。
public enum CSVWriter {
    public static func write(_ sheet: Sheet, styles: StyleTable, dateSystem: DateSystem,
                             format: CSVFormat) throws(CSVWriteError) -> CSVWriteResult {
        let table = fields(of: sheet, styles: styles, dateSystem: dateSystem)
        let separator = String(format.delimiter)
        var text = table.map { $0.map { quoted($0, format.delimiter) }.joined(separator: separator) }
            .joined(separator: format.lineEnding)
        if format.endsWithLineBreak, !table.isEmpty { text += format.lineEnding }
        return CSVWriteResult(data: try encode(text, format), fields: table, format: format)
    }

    /// 把写出来的文件按同样的编码、分隔符用读 csv 的那一套解回来，每个字段一字不差。
    public static func verify(_ data: Data, written: CSVWriteResult) throws(CSVWriteError) {
        var body = data
        if written.format.hasByteOrderMark, let mark = byteOrderMark(written.format.encoding), body.starts(with: mark) {
            body = body.dropFirst(mark.count)
        }
        guard let text = String(data: body, encoding: written.format.encoding) else {
            throw CSVWriteError.verificationFailed("The saved file can't be decoded again.")
        }
        func trimmed(_ rows: [[String]]) -> [[String]] {
            var rows = rows
            while let last = rows.last, last.allSatisfy(\.isEmpty) { rows.removeLast() }
            return rows
        }
        let parsed = trimmed(CSVReader.parse(text, delimiter: written.format.delimiter))
        let expected = trimmed(written.fields)
        guard parsed == expected else {
            let row = zip(parsed, expected).enumerated().first { $0.element.0 != $0.element.1 }?.offset
                ?? min(parsed.count, expected.count)
            throw CSVWriteError.verificationFailed("Row \(row + 1) doesn't match after saving.")
        }
    }

    /// 每格的文字：从第 1 行第 1 列写到用到的范围的右下角，每行一样多的字段（Excel 也这样写）。
    static func fields(of sheet: Sheet, styles: StyleTable, dateSystem: DateSystem) -> [[String]] {
        guard let used = sheet.cells.usedRange else { return [] }
        return (0...used.end.row).map { row in
            (0...used.end.column).map { column in
                sheet.cells[row, column].map { text(of: $0, styles: styles, dateSystem: dateSystem) } ?? ""
            }
        }
    }

    static func text(of cell: Cell, styles: StyleTable, dateSystem: DateSystem) -> String {
        switch cell.value {
        case .empty: return ""
        case .text(let text): return text
        case .bool(let flag): return flag ? "TRUE" : "FALSE"
        case .error(let error): return error == .circular ? "" : error.code
        case .number(let number):
            let code = styles.formatCode(forStyle: cell.styleIndex)
            if ValueFormatter.isDateFormat(code), let date = DateSerial.isoText(number, system: dateSystem) { return date }
            if ValueFormatter.percentCount(code) == 1 { return plain(number * 100) + "%" }
            return plain(number)
        }
    }

    /// 导出给 Python / pandas 的 csv（设计 9.2 节 export_sheet）：UTF-8 不带 BOM、逗号、\n；数字写原值（百分比写小数，
    /// 不加千分位），日期写 ISO（YYYY-MM-DD），公式写算出来的值。和写回用户文件的那套不同：这里只求好读、好算。
    public static func analysisData(_ sheet: Sheet, range: CellRange, styles: StyleTable, dateSystem: DateSystem) -> Data {
        var lines: [String] = []
        for row in range.start.row...range.end.row {
            let fields = (range.start.column...range.end.column).map { column -> String in
                guard let cell = sheet.cells[row, column] else { return "" }
                switch cell.value {
                case .number(let number):
                    if ValueFormatter.isDateFormat(styles.formatCode(forStyle: cell.styleIndex)),
                       let date = DateSerial.isoText(number, system: dateSystem) { return date }
                    return plain(number)
                case .error(let error):
                    return error == .circular ? "" : error.code
                default:
                    return quoted(text(of: cell, styles: styles, dateSystem: dateSystem), ",")
                }
            }
            lines.append(fields.joined(separator: ","))
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private static func plain(_ number: Decimal) -> String {
        DecimalMath.plainString(DecimalMath.roundSignificant(number, digits: 15))
    }

    /// RFC 4180：有分隔符、引号、换行的字段用引号括起来，里面的引号写两个。
    private static func quoted(_ field: String, _ delimiter: Character) -> String {
        let special = field.unicodeScalars.contains { $0 == "\"" || $0 == "\n" || $0 == "\r" }
            || field.contains(delimiter)
        return special ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field
    }

    private static func byteOrderMark(_ encoding: String.Encoding) -> Data? {
        switch encoding {
        case .utf8: Data([0xEF, 0xBB, 0xBF])
        case .utf16LittleEndian: Data([0xFF, 0xFE])
        case .utf16BigEndian: Data([0xFE, 0xFF])
        default: nil
        }
    }

    private static func encode(_ text: String, _ format: CSVFormat) throws(CSVWriteError) -> Data {
        guard let body = text.data(using: format.encoding, allowLossyConversion: false) else {
            let bad = text.first { String($0).data(using: format.encoding, allowLossyConversion: false) == nil } ?? "?"
            throw CSVWriteError.unencodableCharacter(bad)
        }
        guard format.hasByteOrderMark, let mark = byteOrderMark(format.encoding) else { return body }
        return mark + body
    }
}
