import Foundation

/// 收 XML 事件的一方。只有两件事：元素开始；元素结束（带上它直接包含的文字）。
protocol XMLScanHandler: AnyObject {
    /// 根元素所在的命名空间以外，这个部件还要读哪些命名空间里的元素（custom.xml 的值写在 docPropsVTypes 里）。
    var otherNamespaces: Set<String> { get }
    func start(_ element: String, attributes: [String: String])
    func end(_ element: String, text: String)
}

extension XMLScanHandler {
    var otherNamespaces: Set<String> { [] }
}

/// 流式读 XML，xlsx 的每个部件都用它（设计第三节 Package/XMLScanner）。
///
/// 元素按命名空间认，不按前缀：不同的软件给同一个命名空间起的前缀不一样，有的整份文件都写 `<x:c>`。
/// 只有部件的主命名空间（根元素的命名空间，过渡版、严格版、没写命名空间的都一样认）里的元素交给 handler；
/// 别的命名空间里的元素（x15、x14、mc……）和 `extLst` 里的东西是扩展，整棵跳过：保存时它们原文照抄，
/// 但不能改掉读到的数据和设置。以前去掉前缀就认，1904 的工作簿尾部 `<x15:workbookPr>` 把日期系统改回 1900，
/// worksheet 尾部扩展里的 `<e:c r="A1">` 能盖掉真格子的值（读文件排查第 1 条，2026-11-16）。
///
/// 属性：没有前缀的按名字；关系命名空间里的（`r:id`）统一叫 `r:id`；别的命名空间里的保持文件里的写法（`x14ac:dyDescent`），
/// 不会和没有前缀的同名属性撞上，也不会冒充它。
///
/// `mc:AlternateContent`（标记兼容，ECMA-376 第 3 部分）照兼容规则选一支：第一个 Requires 里的命名空间都认识的
/// `mc:Choice`，没有就 `mc:Fallback`；选中那一支里的东西按 AlternateContent 原来的位置读，别的支不读。以前整棵跳过，
/// Fallback 里主命名空间的格子、文字就读丢了（PR #17 第一轮审查第 1 条）。保存时它在 sheet 的顶层原文照抄，没变。
enum XMLScanner {
    /// 关系命名空间（过渡版和严格版）：workbook.xml 的 `<sheet r:id>` 靠它连到 sheet 部件。
    static let relationshipNamespaces: Set<String> = [
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
        "http://purl.oclc.org/ooxml/officeDocument/relationships",
    ]
    /// 标记兼容（mc:AlternateContent、mc:Choice、mc:Fallback）的命名空间。
    static let compatibilityNamespace = "http://schemas.openxmlformats.org/markup-compatibility/2006"

    static func scan(_ data: Data, part: String, handler: some XMLScanHandler) throws(XLSXError) {
        let delegate = Delegate(handler: handler)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else {
            throw XLSXError.malformedXML(part: part, line: parser.lineNumber,
                                         reason: parser.parserError.map { "\($0)" } ?? "unknown error")
        }
    }

    static func localName(_ name: String) -> String {
        guard let colon = name.lastIndex(of: ":") else { return name }
        return String(name[name.index(after: colon)...])
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        /// 没跳过的每一层元素。
        private enum Frame {
            /// 交给了 handler：结束时也交给它。
            case delivered
            /// mc:AlternateContent，`chosen` 是已经选了一支（后面的 Choice、Fallback 都跳过）。
            case alternatives(chosen: Bool)
            /// 选中的那一支：它自己不交给 handler，里面的照常读。
            case branch
        }

        private let handler: any XMLScanHandler
        private let otherNamespaces: Set<String>
        /// 每层元素直接包含的文字。`<t xml:space="preserve"> </t>` 里的空格也要原样留着。跳过的元素也占一层：
        /// 它里面的字不能算进外面那一层。
        private var texts: [String] = []
        /// 根元素的命名空间（没有就是空串）。
        private var mainNamespace: String?
        /// 正在跳过的扩展有几层深：不是 0 就不交给 handler。
        private var skipping = 0
        private var frames: [Frame] = []
        /// 前缀 → 命名空间，按声明的先后压栈（里层的声明盖住外层的）。
        private var prefixes: [String: [String]] = [:]

        init(handler: any XMLScanHandler) {
            self.handler = handler
            otherNamespaces = handler.otherNamespaces
        }

        func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
            prefixes[prefix, default: []].append(namespaceURI)
        }

        func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
            prefixes[prefix]?.removeLast()
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            texts.append("")
            let namespace = namespaceURI ?? ""
            if mainNamespace == nil { mainNamespace = namespace }
            if skipping > 0 {
                skipping += 1
                return
            }
            if namespace == XMLScanner.compatibilityNamespace {
                switch (elementName, frames.last) {
                case ("AlternateContent", _):
                    frames.append(.alternatives(chosen: false))
                case ("Choice", .alternatives(chosen: false)?) where understands(attributeDict["Requires"]),
                     ("Fallback", .alternatives(chosen: false)?):
                    frames[frames.count - 1] = .alternatives(chosen: true)
                    frames.append(.branch)
                default:
                    skipping = 1
                }
                return
            }
            guard namespace == mainNamespace || otherNamespaces.contains(namespace), elementName != "extLst" else {
                skipping = 1
                return
            }
            frames.append(.delivered)
            handler.start(elementName, attributes: attributes(attributeDict))
        }

        /// Choice 的 Requires：几个前缀，指的命名空间都要认识（这个部件的主命名空间、另外要读的）。
        private func understands(_ requires: String?) -> Bool {
            let required = (requires ?? "").split(whereSeparator: \.isWhitespace)
            return !required.isEmpty && required.allSatisfy { prefix in
                guard let namespace = prefixes[String(prefix)]?.last else { return false }
                return namespace == mainNamespace || otherNamespaces.contains(namespace)
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if !texts.isEmpty {
                texts[texts.count - 1] += string
            }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if !texts.isEmpty {
                texts[texts.count - 1] += String(decoding: CDATABlock, as: UTF8.self)
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            let text = texts.popLast() ?? ""
            if skipping > 0 {
                skipping -= 1
                return
            }
            guard case .delivered? = frames.popLast() else { return }
            handler.end(elementName, text: text)
        }

        /// 属性都没有前缀（绝大多数）就直接用，不再抄一份：读十万行的表时每个格子都要抄（2026-11-14）。
        /// 有前缀的先放没有前缀的和关系命名空间的，别的命名空间按文件里的写法放在后面，名字已经有了就不放。
        private func attributes(_ attributeDict: [String: String]) -> [String: String] {
            guard attributeDict.keys.contains(where: { $0.contains(":") }) else { return attributeDict }
            var result: [String: String] = [:]
            var foreign: [(String, String)] = []
            for (key, value) in attributeDict {
                guard let colon = key.firstIndex(of: ":") else {
                    result[key] = value
                    continue
                }
                let prefix = String(key[..<colon])
                if let namespace = prefixes[prefix]?.last, XMLScanner.relationshipNamespaces.contains(namespace) {
                    result["r:" + key[key.index(after: colon)...]] = value
                } else {
                    foreign.append((key, value))
                }
            }
            for (key, value) in foreign where result[key] == nil {
                result[key] = value
            }
            return result
        }
    }
}
