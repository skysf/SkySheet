import Foundation
import SkySheetCore

/// 内部复制不能先显示再猜类型：长数字、时间和错误都会变。Decimal 编成十进制原文，避免 JSON 数字经过 Double 丢精度。
struct CellClip: Codable, Equatable {
    // 结构改变就换类型标识，防止旧版本误读；旧 App 仍可使用同一份系统文字。
    static let pasteboardType = "ai.skylu.skysheet.cells.v3"
    var originRow: Int
    var originColumn: Int
    var rowCount: Int
    var columnCount: Int
    var entries: [Entry]
    private var date1904: Bool
    var dateSystem: DateSystem { date1904 ? .from1904 : .from1900 }

    init(origin: CellAddress, rowCount: Int, columnCount: Int, entries: [Entry], dateSystem: DateSystem) {
        originRow = origin.row
        originColumn = origin.column
        self.rowCount = rowCount
        self.columnCount = columnCount
        self.entries = entries
        date1904 = dateSystem == .from1904
    }

    struct Entry: Codable, Equatable {
        var value: CellValue
        var formula: String?
        var row: Int
        var column: Int
        var numberFormat: String?

        init(_ cell: Cell, row: Int, column: Int, numberFormat: String) {
            // 新公式不能借用源格的文件缓存；平移后它已经是另一个计算。
            value = cell.formula == nil ? cell.value : .empty
            formula = cell.formula?.source
            self.row = row
            self.column = column
            self.numberFormat = numberFormat == "General" ? nil : numberFormat
        }

        private enum CodingKeys: String, CodingKey { case value, formula, row, column, numberFormat }
        private enum Value: Codable {
            case empty, number(String), text(String), bool(Bool), error(String), circular, otherError(String)

            init(_ value: CellValue) {
                self = switch value {
                case .empty: .empty
                case .number(let number): .number(DecimalMath.plainString(number))
                case .text(let text): .text(text)
                case .bool(let flag): .bool(flag)
                case .error(.circular): .circular
                case .error(.other(let code)): .otherError(code)
                case .error(let error): .error(error.code)
                }
            }

            func decoded() throws -> CellValue {
                switch self {
                case .empty: return .empty
                case .number(let text):
                    guard let number = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else {
                        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid decimal"))
                    }
                    return .number(number)
                case .text(let text): return .text(text)
                case .bool(let flag): return .bool(flag)
                case .error(let code): return .error(CellError(code: code))
                case .circular: return .error(.circular)
                case .otherError(let code): return .error(.other(code))
                }
            }
        }

        init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            value = try fields.decode(Value.self, forKey: .value).decoded()
            formula = try fields.decodeIfPresent(String.self, forKey: .formula)
            row = try fields.decode(Int.self, forKey: .row)
            column = try fields.decode(Int.self, forKey: .column)
            numberFormat = try fields.decodeIfPresent(String.self, forKey: .numberFormat)
        }

        func encode(to encoder: any Encoder) throws {
            var fields = encoder.container(keyedBy: CodingKeys.self)
            try fields.encode(Value(value), forKey: .value)
            try fields.encodeIfPresent(formula, forKey: .formula)
            try fields.encode(row, forKey: .row)
            try fields.encode(column, forKey: .column)
            try fields.encodeIfPresent(numberFormat, forKey: .numberFormat)
        }
    }
}

/// TSV 及单格填满选区仍会展开矩形；复制和粘贴在展开之前共用上限。
enum CopyLimit: Error {
    static let cells = 1_000_000
    case exceeded

    static func check(_ range: CellRange) throws {
        // 用除法比较面积，连非法的极大尺寸也不会在乘法里溢出。
        try check(rows: range.rowCount, columns: range.columnCount)
    }

    static func check(rows: Int, columns: Int) throws {
        guard rows > 0, columns > 0, rows <= cells / columns else { throw Self.exceeded }
    }
}
