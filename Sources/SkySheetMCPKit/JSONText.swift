import Foundation

// MARK: - 按原文改 JSON：认出每个值在原文里的位置，只在那儿插进或删掉几个字节（设计 9.5 节）
//
// 为什么有它：Claude Code 的 settings.json 是用户自己的文件，可能手排过、可能进了 git。整份解析再写回去
// （JSONSerialization）会给键排序、换掉冒号两边的空格、丢掉末尾的换行：内容一样，文件却全变了（v0.3.0 在作者
// 机器上碰到，v0.3.1 改成这样）。
// 管什么：给一份合法 JSON 标出每个值的位置；往对象里加一项、往数组里加或删一个元素。新写的部分照着原文的换行、
// 缩进和冒号写，别的字节一个不动。
// 不管什么：验证合法（调用方先交给 JSONSerialization，不合法就一个字节都不写）；注释和 JSON5。

/// 原文里的一个值。`start..<end` 是它在原文（UTF-8 字节）里的位置。
struct JSONTextValue {
    enum Kind {
        case object([JSONTextMember])
        case array([JSONTextValue])
        case string(String)
        /// 数字、true、false、null：用不着它们的值。
        case scalar
    }

    var start: Int
    var end: Int
    var kind: Kind

    var members: [JSONTextMember]? {
        if case .object(let members) = kind { return members }
        return nil
    }

    var elements: [JSONTextValue]? {
        if case .array(let elements) = kind { return elements }
        return nil
    }

    var string: String? {
        if case .string(let text) = kind { return text }
        return nil
    }

    /// 同一个键出现几次时认最后一个，和 Claude Code 的 JavaScript（JSON.parse）一样。
    func member(_ key: String) -> JSONTextMember? {
        members?.last { $0.key == key }
    }
}

/// 对象里的一项。`start` 是键的左引号，`keyEnd` 紧跟着键的右引号。
struct JSONTextMember {
    var key: String
    var start: Int
    var keyEnd: Int
    var value: JSONTextValue
}

/// 要插进去的新值：字符串、数组、对象三种就够用。
enum JSONNewValue {
    case string(String)
    case array([JSONNewValue])
    case object([(key: String, value: JSONNewValue)])
}

/// 新写的部分怎么排。默认值就是 Claude Code 自己写 settings.json 的样子（两格缩进、`": "`）。
struct JSONLayout {
    var newline = "\n"
    var indentUnit = "  "
    /// 键和值中间的那一段：`": "`、`" : "` 或 `":"`。
    var colon = ": "

    /// `indent` 是这个值开头那一行的缩进；nil 表示写成一行。
    func render(_ value: JSONNewValue, indent: String?) -> String {
        let inner = indent.map { $0 + indentUnit }
        switch value {
        case .string(let text):
            return Self.literal(text)
        case .array(let items):
            return block("[", "]", items.map { render($0, indent: inner) }, indent: indent)
        case .object(let members):
            return block("{", "}", members.map { Self.literal($0.key) + colon + render($0.value, indent: inner) },
                         indent: indent)
        }
    }

    /// 一行里项和项之间：冒号后面空一格的文件，逗号后面也空一格。
    var inlineSpace: String { colon.hasSuffix(" ") ? " " : "" }

    private func block(_ open: String, _ close: String, _ items: [String], indent: String?) -> String {
        guard !items.isEmpty else { return open + close }
        guard let indent else { return open + items.joined(separator: "," + inlineSpace) + close }
        let line = newline + indent + indentUnit
        return open + line + items.joined(separator: "," + line) + newline + indent + close
    }

    static func literal(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case _ where scalar.value < 0x20: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}

/// 一份 JSON 原文和扫出来的结构。改动返回新的原文，自己不变。
struct JSONText {
    let bytes: [UInt8]
    let root: JSONTextValue
    let layout: JSONLayout

    /// 只该用在 JSONSerialization 认过的合法 JSON 上；扫不通（不该发生）返回 nil，调用方当成格式不对。
    init?(_ data: Data) {
        bytes = Array(data)
        var scanner = JSONScanner(bytes: bytes)
        scanner.skipByteOrderMark()
        scanner.skipWhitespace()
        guard let root = scanner.value(depth: 0) else { return nil }
        scanner.skipWhitespace()
        guard scanner.atEnd else { return nil }
        self.root = root
        layout = Self.layout(of: bytes, root: root)
    }

    /// 照原文推出来的排法：换行符看有没有 CRLF，缩进和冒号看根对象的第一项。
    private static func layout(of bytes: [UInt8], root: JSONTextValue) -> JSONLayout {
        var layout = JSONLayout()
        if zip(bytes, bytes.dropFirst()).contains(where: { $0 == 0x0D && $1 == 0x0A }) { layout.newline = "\r\n" }
        if let first = root.members?.first {
            layout.colon = String(decoding: bytes[first.keyEnd..<first.value.start], as: UTF8.self)
            if let indent = indent(inGap: gap(in: bytes, before: first.start)), !indent.isEmpty { layout.indentUnit = indent }
        }
        return layout
    }

    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    /// 往对象末尾加一项。`holder` 是装着这个对象的那一项（根对象传 nil），对象是空的时候看它决定写成几行。
    func addingMember(_ key: String, _ value: JSONNewValue, to object: JSONTextValue, in holder: JSONTextMember?) -> Data {
        let members = object.members ?? []
        guard let last = members.last else {
            return filling(object, with: .object([(key, value)]), in: holder)
        }
        let (space, indent) = separator(before: last.start, first: members.count == 1)
        let item = JSONLayout.literal(key) + layout.colon + layout.render(value, indent: indent)
        return replacing(last.value.end..<last.value.end, with: "," + space + item)
    }

    /// 往数组末尾加一个元素。
    func addingElement(_ value: JSONNewValue, to array: JSONTextValue, in holder: JSONTextMember?) -> Data {
        let elements = array.elements ?? []
        guard let last = elements.last else {
            return filling(array, with: .array([value]), in: holder)
        }
        let (space, indent) = separator(before: last.start, first: elements.count == 1)
        return replacing(last.end..<last.end, with: "," + space + layout.render(value, indent: indent))
    }

    /// 删掉数组的第 `index` 个元素，连带一个逗号和该走的空白，别的元素原样不动：
    /// 不是最后一个就删到下一个元素开头；是最后一个就从前一个元素末尾删起；只剩它就变成 `[]`。
    func removingElement(at index: Int, of array: JSONTextValue) -> Data {
        let elements = array.elements ?? []
        if elements.count == 1 { return replacing((array.start + 1)..<(array.end - 1), with: "") }
        if index < elements.count - 1 { return replacing(elements[index].start..<elements[index + 1].start, with: "") }
        return replacing(elements[index - 1].end..<elements[index].end, with: "")
    }

    /// 空的对象或数组（`{}`、`[ ]`）整个换成新写的。根对象、每项一行的对象里的值写成多行，不然写成一行。
    private func filling(_ empty: JSONTextValue, with value: JSONNewValue, in holder: JSONTextMember?) -> Data {
        let multiline = holder.map { gap(before: $0.start).contains(0x0A) } ?? true
        let indent = multiline ? lineIndent(at: empty.start) : nil
        return replacing(empty.start..<empty.end, with: layout.render(value, indent: indent))
    }

    /// 新的一项前面放什么：照抄最后一项前面的空白（每项一行就是换行加缩进），和这一项开头那行的缩进（一行写完的是 nil）。
    /// 最后一项也是第一项时它前面是括号：一行的话看不出逗号后空不空格，照冒号来。
    private func separator(before position: Int, first: Bool) -> (space: String, indent: String?) {
        let space = gap(before: position)
        guard let indent = Self.indent(inGap: space) else {
            return (first ? layout.inlineSpace : String(decoding: space, as: UTF8.self), nil)
        }
        return (String(decoding: space, as: UTF8.self), indent)
    }

    /// 紧挨在 `position` 前面的空白。
    private func gap(before position: Int) -> ArraySlice<UInt8> {
        Self.gap(in: bytes, before: position)
    }

    private static func gap(in bytes: [UInt8], before position: Int) -> ArraySlice<UInt8> {
        var start = position
        while start > 0, isWhitespace(bytes[start - 1]) { start -= 1 }
        return bytes[start..<position]
    }

    /// 空白里最后一个换行后面的那段（就是下一行的缩进）；没有换行返回 nil。
    private static func indent(inGap gap: ArraySlice<UInt8>) -> String? {
        guard let newline = gap.lastIndex(of: 0x0A) else { return nil }
        return String(decoding: gap[(newline + 1)...], as: UTF8.self)
    }

    /// `position` 所在那一行开头的缩进。
    private func lineIndent(at position: Int) -> String {
        var start = position
        while start > 0, bytes[start - 1] != 0x0A { start -= 1 }
        var end = start
        while end < position, bytes[end] == 0x20 || bytes[end] == 0x09 { end += 1 }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    private func replacing(_ range: Range<Int>, with text: String) -> Data {
        var result = bytes
        result.replaceSubrange(range, with: Array(text.utf8))
        return Data(result)
    }
}

/// 从头扫到尾，记下每个值的位置。只认合法 JSON（调用方先验过），扫不通就返回 nil，不猜。
private struct JSONScanner {
    let bytes: [UInt8]
    var index = 0

    var atEnd: Bool { index == bytes.count }

    mutating func skipByteOrderMark() {
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
    }

    mutating func skipWhitespace() {
        while index < bytes.count, JSONText.isWhitespace(bytes[index]) { index += 1 }
    }

    mutating func value(depth: Int) -> JSONTextValue? {
        guard depth < 512, index < bytes.count else { return nil }
        let start = index
        switch bytes[index] {
        case UInt8(ascii: "{"):
            index += 1
            var members: [JSONTextMember] = []
            skipWhitespace()
            if !consume("}") {
                repeat {
                    skipWhitespace()
                    let keyStart = index
                    guard let key = string() else { return nil }
                    let keyEnd = index
                    skipWhitespace()
                    guard consume(":") else { return nil }
                    skipWhitespace()
                    guard let value = value(depth: depth + 1) else { return nil }
                    members.append(JSONTextMember(key: key, start: keyStart, keyEnd: keyEnd, value: value))
                    skipWhitespace()
                } while consume(",")
                guard consume("}") else { return nil }
            }
            return JSONTextValue(start: start, end: index, kind: .object(members))
        case UInt8(ascii: "["):
            index += 1
            var elements: [JSONTextValue] = []
            skipWhitespace()
            if !consume("]") {
                repeat {
                    skipWhitespace()
                    guard let element = value(depth: depth + 1) else { return nil }
                    elements.append(element)
                    skipWhitespace()
                } while consume(",")
                guard consume("]") else { return nil }
            }
            return JSONTextValue(start: start, end: index, kind: .array(elements))
        case UInt8(ascii: "\""):
            guard let text = string() else { return nil }
            return JSONTextValue(start: start, end: index, kind: .string(text))
        default:
            while index < bytes.count, !JSONText.isWhitespace(bytes[index]),
                  ![UInt8(ascii: ","), UInt8(ascii: "]"), UInt8(ascii: "}")].contains(bytes[index]) {
                index += 1
            }
            return index > start ? JSONTextValue(start: start, end: index, kind: .scalar) : nil
        }
    }

    /// 一个字符串（`index` 在左引号上），返回解出来的文字。
    private mutating func string() -> String? {
        guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { return nil }
        let start = index
        var escaped = false
        index += 1
        while index < bytes.count, bytes[index] != UInt8(ascii: "\"") {
            if bytes[index] == UInt8(ascii: "\\") {
                escaped = true
                index += 1
            }
            index += 1
        }
        guard index < bytes.count else { return nil }
        index += 1
        let token = bytes[start..<index]
        guard escaped else { return String(decoding: token.dropFirst().dropLast(), as: UTF8.self) }
        // 有转义（\n、A……）：交给 JSONSerialization 解，不自己再抄一遍规则。
        return (try? JSONSerialization.jsonObject(with: Data(token), options: .fragmentsAllowed)) as? String
    }

    private mutating func consume(_ character: Unicode.Scalar) -> Bool {
        guard index < bytes.count, bytes[index] == UInt8(ascii: character) else { return false }
        index += 1
        return true
    }
}
