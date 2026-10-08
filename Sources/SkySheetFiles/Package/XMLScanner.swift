import Foundation

/// 收 XML 事件的一方。只有两件事：元素开始；元素结束（带上它直接包含的文字）。
protocol XMLScanHandler: AnyObject {
    func start(_ element: String, attributes: [String: String])
    func end(_ element: String, text: String)
}

/// 流式读 XML，xlsx 的每个部件都用它（设计第三节 Package/XMLScanner）。
///
/// 元素名和属性名都去掉命名空间前缀（`r:id` → `id`，`x:c` → `c`）：不同的软件给同一个命名空间起的前缀不一样，
/// 有的整份文件都写 `<x:c>`。我们读的元素里没有去掉前缀后会撞名的属性。
enum XMLScanner {
    static func scan(_ data: Data, part: String, handler: some XMLScanHandler) throws(XLSXError) {
        let delegate = Delegate(handler: handler)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
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
        private let handler: any XMLScanHandler
        /// 每层元素直接包含的文字。`<t xml:space="preserve"> </t>` 里的空格也要原样留着。
        private var texts: [String] = []

        init(handler: any XMLScanHandler) {
            self.handler = handler
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            var attributes: [String: String] = [:]
            for (key, value) in attributeDict {
                attributes[XMLScanner.localName(key)] = value
            }
            texts.append("")
            handler.start(XMLScanner.localName(elementName), attributes: attributes)
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
            handler.end(XMLScanner.localName(elementName), text: texts.popLast() ?? "")
        }
    }
}
