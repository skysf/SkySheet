import Foundation

// MARK: - 工具清单：一份，两边用（设计 9.1 节第 1 条、9.2 节）
//
// 管什么：SkySheet 给 AI 的每一个工具叫什么、干什么、收什么参数（JSON Schema）。
// 小程序回 `tools/list` 读它，App 分派 `tools/call` 也按 `MCPToolName` 走 —— 两边的 switch 都是穷举的，
// **加一个工具漏了哪一边，编译器当场报错**。
// 不管什么：工具真正怎么做（App 里的 AI/ 目录）。
//
// 说明文字只用英文（模型读英文最准，一个汉字都不夹；AI 回用户时用用户的语言）。每条写清：做什么、不传的参数怎么办、
// 什么时候会被拒绝。每条说明不超过 2,048 个字符：Claude Code 只读这么多（自检钉着）。
// 各个工具的文字在 MCPReadTools、MCPWriteTools 里。

/// 全部工具的名字。**顺序就是 `tools/list` 的顺序**（2026-07-28 版协议要求清单顺序稳定）。
public enum MCPToolName: String, CaseIterable, Sendable {
    case getStatus = "get_status"
    case openFile = "open_file"
    case describeSheet = "describe_sheet"
    case readRange = "read_range"
    case query = "query"
    case evaluate = "evaluate"
    case exportSheet = "export_sheet"
    case show = "show"
    case addSheet = "add_sheet"
    case writeCells = "write_cells"
    case formatCells = "format_cells"
    case editSheet = "edit_sheet"
    case undo = "undo"
    case saveCopy = "save_copy"

    public var definition: MCPToolDefinition {
        switch self {
        case .getStatus, .openFile, .describeSheet, .readRange, .query, .evaluate, .exportSheet, .show, .saveCopy:
            return MCPReadTools.definition(for: self)
        case .addSheet, .writeCells, .formatCells, .editSheet, .undo:
            return MCPWriteTools.definition(for: self)
        }
    }

    /// `tools/list` 的 `tools` 数组。
    public static var listJSON: JSONValue {
        .array(allCases.map(\.definition.json))
    }
}

/// 一个工具的说明书。
public struct MCPToolDefinition: Sendable {
    public var name: MCPToolName
    public var title: String
    public var description: String
    public var inputSchema: JSONValue
    /// 只读：不改工作簿、不写用户的文件（客户端据此决定要不要每次都问用户；设计 9.1 节第 5 条）。
    public var readOnly: Bool
    /// 会删掉东西（删 AI 的 sheet）。SkySheet 从不覆盖文件，所以「写新文件」的工具不算。
    public var destructive: Bool

    public init(_ name: MCPToolName, title: String, description: String, input: JSONValue = MCPSchema.object([:]),
                readOnly: Bool = false, destructive: Bool = false) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = input
        self.readOnly = readOnly
        self.destructive = destructive
    }

    public var json: JSONValue {
        [
            "name": .string(name.rawValue),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": [
                "title": .string(title),
                "readOnlyHint": .bool(readOnly),
                "destructiveHint": .bool(destructive),
                "idempotentHint": .bool(readOnly),
                // 全在这台 Mac 上做，不上网。
                "openWorldHint": false
            ]
        ]
    }
}

/// 写 JSON Schema 的几个小积木。只放清单里真用到的几种。
public enum MCPSchema {
    public static func object(_ properties: [String: JSONValue], required: [String] = [],
                              description: String? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "object", "properties": .object(properties)]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        if let description { schema["description"] = .string(description) }
        return .object(schema)
    }

    public static func string(_ description: String, oneOf values: [String]? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "string", "description": .string(description)]
        if let values { schema["enum"] = .array(values.map { .string($0) }) }
        return .object(schema)
    }

    public static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "integer", "description": .string(description)]
        if let minimum { schema["minimum"] = .number(Double(minimum)) }
        if let maximum { schema["maximum"] = .number(Double(maximum)) }
        return .object(schema)
    }

    public static func number(_ description: String, minimum: Double? = nil, maximum: Double? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "number", "description": .string(description)]
        if let minimum { schema["minimum"] = .number(minimum) }
        if let maximum { schema["maximum"] = .number(maximum) }
        return .object(schema)
    }

    public static func boolean(_ description: String) -> JSONValue {
        ["type": "boolean", "description": .string(description)]
    }

    public static func array(of items: JSONValue, _ description: String, minItems: Int? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "array", "items": items, "description": .string(description)]
        if let minItems { schema["minItems"] = .number(Double(minItems)) }
        return .object(schema)
    }

    /// 好几个工具都收的参数。
    public static let workbook = string(
        "File name or path of an open workbook (see get_status). Omit to use the current one: the one you opened or "
            + "used last, else the window in front.")
    public static let sheet = string("Sheet name (case-insensitive).")
}

/// 工具参数里的选项词表。小程序不链接 SkySheetCore，拿不到 `FormatPreset`，只能抄一份；
/// 抄的就会漂，自检逐项和 `FormatPreset.allCases` 对账。
public enum MCPVocabulary {
    /// = `FormatPreset.allCases` 的原始值：人民币两位小数、人民币取整、万元一位小数、万元精确、百分比、日期、中文日期。
    public static let numberFormatPresets = ["cny", "cny_int", "wan", "wan_exact", "percent", "date_cn", "date"]
    /// read_range 可以多要的两样。
    public static let readExtras = ["text", "formulas"]
}
