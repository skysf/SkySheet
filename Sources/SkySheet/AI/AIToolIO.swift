import Foundation
import SkySheetCore
import SkySheetMCPKit

// MARK: - AI 工具的进与出（从 SrtFlow 搬来，加了表格用的几样）
//
// 管什么：把 AI 传来的参数读成类型（读错了给一句 AI 看得懂的话）、把结果写成 MCP 的 CallToolResult、
// 格子的值怎么写进 JSON。
// 参数读得**宽一点**：模型偶尔把数字写成 "3.5"、把布尔写成 "true"，照收；但类型真不对（给了个数组）就报错，
// 别悄悄当成没传。

/// 工具没做成，原因写给 AI 看（英文，AI 会用用户的语言转述）。
struct AIToolError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

struct AIToolArguments {
    let raw: JSONValue

    init(_ raw: JSONValue) { self.raw = raw }

    func has(_ key: String) -> Bool {
        guard let value = raw[key] else { return false }
        return !value.isNull
    }

    func string(_ key: String) throws -> String? {
        guard let value = raw[key], !value.isNull else { return nil }
        switch value {
        case .string(let text): return text
        case .number(let number): return number.rounded() == number ? String(Int(number)) : String(number)
        default: throw AIToolError("\(key) must be a string.")
        }
    }

    func requiredString(_ key: String) throws -> String {
        guard let text = try string(key), !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw AIToolError("\(key) is required.")
        }
        return text
    }

    func double(_ key: String) throws -> Double? {
        guard let value = raw[key], !value.isNull else { return nil }
        switch value {
        case .number(let number) where number.isFinite: return number
        case .string(let text):
            if let number = Double(text.trimmingCharacters(in: .whitespaces)), number.isFinite { return number }
        default: break
        }
        throw AIToolError("\(key) must be a number.")
    }

    func int(_ key: String) throws -> Int? {
        guard let number = try double(key) else { return nil }
        guard number.rounded() == number, abs(number) < 1e9 else { throw AIToolError("\(key) must be a whole number.") }
        return Int(number)
    }

    func bool(_ key: String) throws -> Bool? {
        guard let value = raw[key], !value.isNull else { return nil }
        switch value {
        case .bool(let flag): return flag
        case .string(let text) where ["true", "false"].contains(text.lowercased()): return text.lowercased() == "true"
        case .number(let number) where number == 0 || number == 1: return number == 1
        default: throw AIToolError("\(key) must be true or false.")
        }
    }

    func array(_ key: String) throws -> [JSONValue]? {
        guard let value = raw[key], !value.isNull else { return nil }
        guard case .array(let items) = value else { throw AIToolError("\(key) must be a list.") }
        return items
    }

    func object(_ key: String) throws -> [String: JSONValue]? {
        guard let value = raw[key], !value.isNull else { return nil }
        guard case .object(let object) = value else { throw AIToolError("\(key) must be an object.") }
        return object
    }

    func stringArray(_ key: String) throws -> [String]? {
        try array(key).map { items in
            try items.map { item in
                guard let text = item.stringValue else { throw AIToolError("Every entry of \(key) must be a string.") }
                return text
            }
        }
    }
}

/// 一个工具的结果。
struct AIToolResult {
    var payload: JSONValue
    var isError = false
    /// 工作簿被改了（算进这一轮的改动数）。
    var changed = false

    static func ok(_ payload: JSONValue, changed: Bool = false) -> AIToolResult {
        AIToolResult(payload: payload, changed: changed)
    }

    /// MCP 的 CallToolResult：结果写成一段 JSON 文字（所有客户端都认文字）。
    var json: JSONValue {
        MCPBridge.textResult(payload.encodedString(), isError: isError)
    }
}

/// 格子、区域、值在结果里的写法。
enum AIFormat {
    /// 值：数字是数字（Decimal 换成 Double，十几位有效数字，够看也够算），日期是序列号，错误写成 "#DIV/0!"，空是 null。
    static func json(_ value: CellValue) -> JSONValue {
        switch value {
        case .empty: .null
        case .number(let number): .number(DecimalMath.double(number))
        case .text(let text): .string(text)
        case .bool(let flag): .bool(flag)
        case .error(let error): .string(error.code)
        }
    }

    static func json(_ decimal: Decimal?) -> JSONValue {
        decimal.map { .number(DecimalMath.double($0)) } ?? .null
    }

    /// "B2"、"A1:C3"、"Loan!A1:C3" 这样的区域。带了 sheet 名就把它也拆出来。
    static func range(_ text: String) throws -> (sheet: String?, range: CellRange) {
        var body = text.trimmingCharacters(in: .whitespaces)
        var sheet: String?
        if let bang = body.lastIndex(of: "!") {
            var name = String(body[..<bang])
            if name.hasPrefix("'"), name.hasSuffix("'"), name.count >= 2 {
                name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            }
            sheet = name
            body = String(body[body.index(after: bang)...])
        }
        guard let range = CellRange(a1: body) else {
            throw AIToolError("\(text) is not a cell or range like B2 or A1:C10.")
        }
        return (sheet, range)
    }

    static func address(_ text: String) throws -> CellAddress {
        guard let address = CellAddress(a1: text.trimmingCharacters(in: .whitespaces)) else {
            throw AIToolError("\(text) is not a cell like B2.")
        }
        return address
    }

    /// "#C00000"、"C00000"、"#FFC00000" → ARGB "FFC00000"。
    static func color(_ text: String, key: String) throws -> String {
        var hex = text.trimmingCharacters(in: .whitespaces).uppercased()
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard [6, 8].contains(hex.count), hex.allSatisfy(\.isHexDigit) else {
            throw AIToolError("\(key) must be a hex color like #C00000.")
        }
        return hex.count == 6 ? "FF" + hex : hex
    }
}
