import Foundation
import SkySheetCore

/// 内部复制不能先显示再猜类型：长数字、时间和错误都会变。Decimal 编成十进制原文，避免 JSON 数字经过 Double 丢精度。
struct CellClip: Codable, Equatable {
    // 旧格式只有文字，不能当成带类型的新格式读；旧 App 仍能使用同一份系统文字。
    static let pasteboardType = "ai.skylu.skysheet.cells.v2"
    var originRow: Int
    var originColumn: Int
    var rows: [[Entry]]
    private var date1904: Bool
    var dateSystem: DateSystem { date1904 ? .from1904 : .from1900 }

    init(origin: CellAddress, rows: [[Entry]], dateSystem: DateSystem) {
        originRow = origin.row
        originColumn = origin.column
        self.rows = rows
        date1904 = dateSystem == .from1904
    }

    struct Entry: Codable, Equatable {
        var value: CellValue
        var formula: String?

        init(_ cell: Cell) {
            value = cell.value
            formula = cell.formula?.source
        }

        private enum CodingKeys: String, CodingKey { case value, formula }
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
        }

        func encode(to encoder: any Encoder) throws {
            var fields = encoder.container(keyedBy: CodingKeys.self)
            try fields.encode(Value(value), forKey: .value)
            try fields.encodeIfPresent(formula, forKey: .formula)
        }
    }
}

/// 两份复制数据都要密集展开矩形，必须在分配任何数组之前共用这一上限。
enum CopyLimit: Error {
    static let cells = 1_000_000
    case exceeded

    static func check(_ range: CellRange) throws {
        // 用除法比较面积，连非法的极大尺寸也不会在乘法里溢出。
        guard range.rowCount <= cells / range.columnCount else { throw Self.exceeded }
    }
}
