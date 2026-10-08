import Foundation
import SkySheetCore

/// 读进来的 csv：一张 sheet 的工作簿，加上原来的编码、分隔符。M3 写回 csv 时照原样用（设计 7.3 节）。
public struct CSVDocument: Sendable {
    public var workbook: Workbook
    public var encoding: String.Encoding
    public var hasByteOrderMark: Bool
    public var delimiter: Character
}

public enum CSVError: Error, Equatable, Sendable {
    /// 既不是 UTF-8 / UTF-16，也不是 GB18030。
    case unreadableText
}

/// 读 csv / tsv（设计 7.3 节）。
public enum CSVReader {
    public static func read(contentsOf url: URL) throws -> CSVDocument {
        try read(Data(contentsOf: url), sheetName: url.deletingPathExtension().lastPathComponent)
    }

    public static func read(_ data: Data, sheetName: String) throws(CSVError) -> CSVDocument {
        guard let decoded = TextEncodingSniffer.decode(data) else { throw CSVError.unreadableText }
        let delimiter = detectDelimiter(decoded.text)
        var sheet = Sheet(id: 1, name: sheetName.isEmpty ? "Sheet1" : sheetName)
        for (row, fields) in parse(decoded.text, delimiter: delimiter).enumerated() {
            for (column, field) in fields.enumerated() where !field.isEmpty {
                sheet.cells[row, column] = CSVValue.cell(for: field)
            }
        }
        let workbook = Workbook(sheets: [sheet], styles: CSVValue.styles)
        return CSVDocument(workbook: workbook, encoding: decoded.encoding, hasByteOrderMark: decoded.byteOrderMark,
                           delimiter: delimiter)
    }

    /// RFC 4180：字段可以用双引号括起来，里面的 "" 是一个引号，可以有分隔符和换行。行尾认 \r\n、\n、\r。
    static func parse(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var fields: [String] = []
        var field = ""
        var quoted = false
        var characters = text.makeIterator()
        var pending = characters.next()
        while let character = pending {
            pending = characters.next()
            if quoted {
                if character == "\"" {
                    if pending == "\"" {
                        field.append("\"")
                        pending = characters.next()
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"" where field.isEmpty:
                quoted = true
            case delimiter:
                fields.append(field)
                field = ""
            case "\r\n", "\n", "\r":
                fields.append(field)
                rows.append(fields)
                fields = []
                field = ""
            default:
                field.append(character)
            }
        }
        if !field.isEmpty || !fields.isEmpty {
            fields.append(field)
            rows.append(fields)
        }
        return rows
    }

    /// 在逗号、制表符、分号、竖线里挑：前 50 行里，每行（引号外）出现次数最一致、又不是 0 的那个。一样好时按这个顺序优先。
    static func detectDelimiter(_ text: String) -> Character {
        let candidates: [Character] = [",", "\t", ";", "|"]
        var lines: [[Character: Int]] = []
        var counts: [Character: Int] = [:]
        var quoted = false
        for character in text {
            if lines.count >= 50 { break }
            if character == "\"" { quoted.toggle() }
            if quoted { continue }
            if character == "\n" || character == "\r\n" || character == "\r" {
                lines.append(counts)
                counts = [:]
            } else if candidates.contains(character) {
                counts[character, default: 0] += 1
            }
        }
        if !counts.isEmpty { lines.append(counts) }
        var best: (delimiter: Character, score: Int) = (",", 0)
        for candidate in candidates {
            let perLine = lines.map { $0[candidate] ?? 0 }
            let frequencies = Dictionary(grouping: perLine.filter { $0 > 0 }, by: { $0 }).mapValues(\.count)
            let score = frequencies.values.max() ?? 0
            if score > best.score { best = (candidate, score) }
        }
        return best.delimiter
    }
}

/// 字段的文字转成格子的值。宁可留成文字也不乱转：带前导 0 的数（账号、编号）、超过 15 位的数字串（卡号、证件号）
/// 都保持文字，Excel 会把它们变成 123 或者 1.23E+17，数据就毁了。带千分位、¥ 的也先当文字，AI 需要时自己转。
enum CSVValue {
    static let dateStyle = 1
    static let dateTimeStyle = 2
    static let percentStyle = 3
    static let percentDecimalStyle = 4

    static let styles = StyleTable(
        customNumberFormats: [164: "yyyy-mm-dd", 165: "yyyy-mm-dd hh:mm:ss"],
        cellFormats: [CellFormat(), CellFormat(numberFormatID: 164), CellFormat(numberFormatID: 165),
                      CellFormat(numberFormatID: 9), CellFormat(numberFormatID: 10)])

    static func cell(for field: String) -> Cell {
        let text = field.trimmingCharacters(in: .whitespaces)
        switch text.uppercased() {
        case "TRUE": return Cell(value: .bool(true))
        case "FALSE": return Cell(value: .bool(false))
        default: break
        }
        if let serial = date(text) {
            return Cell(value: .number(serial), styleIndex: DecimalMath.isInteger(serial) ? dateStyle : dateTimeStyle)
        }
        guard keepsMeaningAsNumber(text), let number = DecimalMath.parse(text) else { return Cell(value: .text(field)) }
        if text.hasSuffix("%") {
            return Cell(value: .number(number), styleIndex: text.contains(".") ? percentDecimalStyle : percentStyle)
        }
        return Cell(value: .number(number))
    }

    private static func keepsMeaningAsNumber(_ text: String) -> Bool {
        let digits = text.filter(\.isNumber)
        guard digits.count <= 15 else { return false }
        let unsigned = text.hasPrefix("-") || text.hasPrefix("+") ? String(text.dropFirst()) : text
        if unsigned.count > 1, unsigned.hasPrefix("0"), !unsigned.hasPrefix("0.") { return false }
        return true
    }

    /// 2025-12-01、2025/12/1，可以带 10:30 或 10:30:15。年份四位，月日要合法。
    static func date(_ text: String) -> Decimal? {
        let parts = text.split(separator: " ", maxSplits: 1)
        let pieces = parts[0].split(whereSeparator: { $0 == "-" || $0 == "/" }).map(String.init)
        guard pieces.count == 3, pieces[0].count == 4, let year = Int(pieces[0]), let month = Int(pieces[1]),
              let day = Int(pieces[2]), (1900...9999).contains(year), (1...12).contains(month),
              (1...DateSerial.daysInMonth(year: year, month: month)).contains(day)
        else { return nil }
        var serial = Decimal(DateSerial.serial(from: CivilDate(year: year, month: month, day: day), system: .from1900))
        if parts.count == 2 {
            let clock = parts[1].split(separator: ":").map { Int($0) }
            guard (2...3).contains(clock.count), let hour = clock[0], let minute = clock[1],
                  (0...23).contains(hour), (0...59).contains(minute) else { return nil }
            let second = clock.count == 3 ? (clock[2] ?? 0) : 0
            serial += Decimal(hour * 3600 + minute * 60 + second) / 86_400
        }
        return serial
    }
}

/// 认文字编码：带 BOM 的按 BOM；整份是合法 UTF-8 就是 UTF-8；否则当 GB18030
/// （国内 Excel 和银行导出的 csv 多是 GBK，GB18030 是它的超集）。
enum TextEncodingSniffer {
    static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

    static func decode(_ data: Data) -> (text: String, encoding: String.Encoding, byteOrderMark: Bool)? {
        let boms: [([UInt8], String.Encoding)] = [([0xEF, 0xBB, 0xBF], .utf8), ([0xFF, 0xFE], .utf16LittleEndian),
                                                   ([0xFE, 0xFF], .utf16BigEndian)]
        for (bom, encoding) in boms where data.starts(with: bom) {
            guard let text = String(data: data.dropFirst(bom.count), encoding: encoding) else { return nil }
            return (text, encoding, true)
        }
        if let text = String(data: data, encoding: .utf8) { return (text, .utf8, false) }
        if let text = String(data: data, encoding: gb18030) { return (text, gb18030, false) }
        return nil
    }
}
