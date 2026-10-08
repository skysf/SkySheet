import Foundation

/// 一个 XML 部件拆成：根元素的开始标签、根元素的每个直接子元素（原文）、结束标签（设计 7.2 节「认识的重写，其余原样」）。
/// 改的时候只替换我们管的那几个子元素，别的原文照抄；新元素按 schema 规定的顺序插进去（顺序错了 Excel 报文件损坏）。
///
/// 按字节扫：XML 的分隔符都是 ASCII，UTF-8 的多字节字符里不会出现 < > " 这些字节。注释、CDATA、处理指令都跳过。
/// 子元素里面的东西原文保留；子元素之间的空白和注释不保留（OOXML 里它们没有意义）。
struct XMLFragments {
    struct Child: Equatable {
        let name: String
        var raw: String
    }

    /// 根元素之前的东西（XML 声明）。
    var declaration: String
    var rootStart: String
    let rootName: String
    var children: [Child]

    /// 根元素用的命名空间前缀，带冒号（"x:"），没有就是空串。生成的子元素要用同一个前缀。
    var prefix: String {
        rootName.contains(":") ? String(rootName[...rootName.firstIndex(of: ":")!]) : ""
    }

    init(declaration: String = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n",
         rootStart: String, rootName: String, children: [Child] = []) {
        self.declaration = declaration
        self.rootStart = rootStart
        self.rootName = rootName
        self.children = children
    }

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        var index = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        let bodyStart = index
        var depth = 0
        var childStart: Int?
        var root: (start: String, name: String, declarationEnd: Int)?
        var found: [Child] = []

        func text(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
        func starts(_ literal: String, at position: Int) -> Bool {
            let pattern = Array(literal.utf8)
            return position + pattern.count <= bytes.count && Array(bytes[position..<position + pattern.count]) == pattern
        }
        func find(_ literal: String, from position: Int) -> Int? {
            let pattern = Array(literal.utf8)
            var cursor = position
            while cursor + pattern.count <= bytes.count {
                if bytes[cursor] == pattern[0], Array(bytes[cursor..<cursor + pattern.count]) == pattern { return cursor }
                cursor += 1
            }
            return nil
        }
        /// 标签的结尾 ">"：引号里的 ">" 不算。
        func tagEnd(from position: Int) -> Int? {
            var quote: UInt8?
            var cursor = position
            while cursor < bytes.count {
                let byte = bytes[cursor]
                if let open = quote {
                    if byte == open { quote = nil }
                } else if byte == 0x22 || byte == 0x27 {
                    quote = byte
                } else if byte == 0x3E {
                    return cursor
                }
                cursor += 1
            }
            return nil
        }

        while index < bytes.count {
            guard bytes[index] == 0x3C else { index += 1; continue }
            if starts("<?", at: index) {
                guard let end = find("?>", from: index) else { return nil }
                index = end + 2
            } else if starts("<!--", at: index) {
                guard let end = find("-->", from: index) else { return nil }
                index = end + 3
            } else if starts("<![CDATA[", at: index) {
                guard let end = find("]]>", from: index) else { return nil }
                index = end + 3
            } else if starts("<!", at: index) {
                guard let end = tagEnd(from: index) else { return nil }
                index = end + 1
            } else if starts("</", at: index) {
                guard let end = tagEnd(from: index) else { return nil }
                depth -= 1
                if depth == 1, let start = childStart {
                    found.append(Child(name: Self.localName(text(start..<end + 1)), raw: text(start..<end + 1)))
                    childStart = nil
                }
                if depth == 0 { break }
                index = end + 1
            } else {
                guard let end = tagEnd(from: index) else { return nil }
                let selfClosing = bytes[end - 1] == 0x2F
                let tag = text(index..<end + 1)
                switch depth {
                case 0:
                    root = (tag, Self.qualifiedName(tag), index)
                    if selfClosing {
                        depth = -1
                    } else {
                        depth = 1
                    }
                case 1:
                    if selfClosing {
                        found.append(Child(name: Self.localName(tag), raw: tag))
                    } else {
                        childStart = index
                        depth = 2
                    }
                default:
                    if !selfClosing { depth += 1 }
                }
                if depth == -1 { break }
                index = end + 1
            }
        }
        guard let root else { return nil }
        declaration = text(bodyStart..<root.declarationEnd)
        // 自闭合的根元素（<Types/>）写回时要能放子元素：换成开始标签。
        rootStart = root.start.hasSuffix("/>") ? String(root.start.dropLast(2)) + ">" : root.start
        rootName = root.name
        children = found
    }

    func child(_ name: String) -> Child? {
        children.first { $0.name == name }
    }

    /// 换掉、插入或删除（raw 为 nil）一个子元素。插入时放在 `order` 里排在它前面的最后一个元素后面。
    mutating func set(_ name: String, raw: String?, order: [String]) {
        if let position = children.firstIndex(where: { $0.name == name }) {
            if let raw {
                children[position].raw = raw
            } else {
                children.remove(at: position)
            }
            return
        }
        guard let raw else { return }
        let rank = order.firstIndex(of: name) ?? order.count
        let insertAt = children.lastIndex { (order.firstIndex(of: $0.name) ?? order.count) <= rank }.map { $0 + 1 } ?? 0
        children.insert(Child(name: name, raw: raw), at: insertAt)
    }

    func serialized() -> Data {
        var text = declaration + rootStart
        for child in children { text += child.raw }
        text += "</\(rootName)>"
        return Data(text.utf8)
    }

    /// 往一个列表元素（`<fonts count="3">…</fonts>`）末尾追加几项，count 改成追加后的子元素个数。
    /// 原来没有这个元素就新建一个。原来的拆不开返回 nil。
    static func appending(_ items: [String], to raw: String?, name: String) -> String? {
        guard let raw else { return "<\(name) count=\"\(items.count)\">\(items.joined())</\(name)>" }
        guard var list = XMLFragments(Data(raw.utf8)) else { return nil }
        list.children += items.map { Child(name: localName($0), raw: $0) }
        list.rootStart = settingAttribute("count", to: String(list.children.count), in: list.rootStart)
        list.declaration = ""
        return String(decoding: list.serialized(), as: UTF8.self)
    }

    /// 开始标签 `<x:sheetView a="1">` 里的名字（带前缀）。
    static func qualifiedName(_ tag: String) -> String {
        let body = tag.drop { $0 == "<" || $0 == "/" }
        return String(body.prefix { !$0.isWhitespace && $0 != ">" && $0 != "/" })
    }

    static func localName(_ tag: String) -> String {
        let name = qualifiedName(tag)
        return name.split(separator: ":").last.map(String.init) ?? name
    }

    /// 在 `element` 的第一个标签（开始标签）上设一个属性：有就换值，没有就加上；`value` 为 nil 删掉它。
    /// 只动第一个标签，子元素里同名的属性不碰。
    static func settingAttribute(_ name: String, to value: String?, in element: String) -> String {
        let tagEnd = firstTagEnd(element)
        var tag = String(element[..<tagEnd])
        let rest = element[tagEnd...]
        let pattern = "\\s" + NSRegularExpression.escapedPattern(for: name) + "\\s*=\\s*(\"[^\"]*\"|'[^']*')"
        if let range = tag.range(of: pattern, options: .regularExpression) {
            tag.replaceSubrange(range, with: value.map { " \(name)=\"\(XMLText.attribute($0))\"" } ?? "")
        } else if let value {
            let insertAt = tag.hasSuffix("/>") ? tag.index(tag.endIndex, offsetBy: -2) : tag.index(before: tag.endIndex)
            tag.insert(contentsOf: " \(name)=\"\(XMLText.attribute(value))\"", at: insertAt)
        }
        return tag + rest
    }

    /// `element` 的第一个标签上一个属性的值，实体换回字符。没有返回 nil。
    static func attribute(_ name: String, in element: String) -> String? {
        let tag = String(element[..<firstTagEnd(element)])
        let pattern = "\\s" + NSRegularExpression.escapedPattern(for: name) + "\\s*=\\s*(\"([^\"]*)\"|'([^']*)')"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for group in [2, 3] {
            if let range = Range(match.range(at: group), in: tag) { return XMLText.unescape(String(tag[range])) }
        }
        return nil
    }

    /// 第一个标签结尾 ">" 之后的位置（引号里的 ">" 不算）。
    private static func firstTagEnd(_ element: String) -> String.Index {
        var quote: Character?
        var index = element.startIndex
        while index < element.endIndex {
            let character = element[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return element.index(after: index)
            }
            index = element.index(after: index)
        }
        return element.endIndex
    }

    /// 根元素上给某个命名空间起的前缀（带冒号）。没声明返回 nil。
    func prefix(forNamespace namespace: String) -> String? {
        let pattern = "xmlns:([A-Za-z_][\\w.-]*)\\s*=\\s*\"" + NSRegularExpression.escapedPattern(for: namespace) + "\""
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: rootStart, range: NSRange(rootStart.startIndex..., in: rootStart)),
              let range = Range(match.range(at: 1), in: rootStart) else { return nil }
        return String(rootStart[range]) + ":"
    }
}

/// XML 里文字和属性值的转义，加上 OOXML 自己的 `_xHHHH_` 写法（XML 放不下的控制字符；Excel 把换行里的 \r 写成 _x000D_）。
enum XMLText {
    static func text(_ value: String) -> String {
        // 第一步：原文里本来就有 _x0041_ 这种样子的，开头的下划线写成 _x005F_，读回来才不会被当成转义。
        // 必须先做这一步：第二步生成的 _x000D_ 不能再被保护一遍。
        let guarded = value.replacingOccurrences(of: "_(?=x[0-9A-Fa-f]{4}_)", with: "_x005F_", options: .regularExpression)
        // 第二步：XML 的 & < > 写成实体，放不下的控制字符写成 _xHHHH_。
        var result = ""
        for scalar in guarded.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\t", "\n": result.unicodeScalars.append(scalar)
            default:
                if scalar.value < 0x20 || scalar.value == 0xFFFE || scalar.value == 0xFFFF {
                    result += String(format: "_x%04X_", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }

    static func attribute(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "\n": result += "&#10;"
            case "\t": result += "&#9;"
            case "\r": result += "&#13;"
            default:
                // 别的控制字符 XML 1.0 里怎么写都不合法，去掉（名字、格式代码里本来就不该有）。
                if scalar.value >= 0x20 && scalar.value != 0xFFFE && scalar.value != 0xFFFF {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }

    /// 公式原文：只转 XML 的实体，不用 _xHHHH_（读的时候 `<f>` 里不解这种转义）。\r 写成字符引用才不会被当成换行吞掉。
    static func formula(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\r": result += "&#13;"
            case "\t", "\n": result.unicodeScalars.append(scalar)
            default:
                if scalar.value >= 0x20 && scalar.value != 0xFFFE && scalar.value != 0xFFFF {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }

    /// 属性值里的实体换回字符：&amp; &lt; &gt; &quot; &apos; 和 &#10; &#x0A; 这样的字符引用。
    static func unescape(_ value: String) -> String {
        guard value.contains("&") else { return value }
        var result = ""
        var rest = Substring(value)
        while let ampersand = rest.firstIndex(of: "&") {
            result += rest[..<ampersand]
            guard let semicolon = rest[ampersand...].firstIndex(of: ";") else { break }
            let entity = rest[rest.index(after: ampersand)..<semicolon]
            var scalar: Unicode.Scalar?
            switch entity {
            case "amp": scalar = "&"
            case "lt": scalar = "<"
            case "gt": scalar = ">"
            case "quot": scalar = "\""
            case "apos": scalar = "'"
            default:
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    scalar = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init)
                } else if entity.hasPrefix("#") {
                    scalar = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init)
                }
            }
            if let scalar {
                result.unicodeScalars.append(scalar)
            } else {
                result += rest[ampersand...semicolon]
            }
            rest = rest[rest.index(after: semicolon)...]
        }
        return result + rest
    }

    /// 读的时候把 `_xHHHH_` 换回字符（_x005F_ 是下划线本身）。
    static func decodeEscapes(_ value: String) -> String {
        guard value.contains("_x") else { return value }
        let expression = try! NSRegularExpression(pattern: "_x([0-9A-Fa-f]{4})_")
        var result = ""
        var cursor = value.startIndex
        for match in expression.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
            guard let whole = Range(match.range, in: value), let hex = Range(match.range(at: 1), in: value),
                  let code = UInt32(value[hex], radix: 16), let scalar = Unicode.Scalar(code) else { continue }
            result += value[cursor..<whole.lowerBound]
            result.unicodeScalars.append(scalar)
            cursor = whole.upperBound
        }
        return result + value[cursor...]
    }
}
