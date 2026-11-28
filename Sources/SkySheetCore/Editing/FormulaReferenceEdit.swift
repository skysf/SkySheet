import Foundation

/// 点选后保留刚插入的那段文字。继续点或拖只替换这一段，打出运算符后才开始下一个引用。
/// 两端的系统文本框都用 UTF-16 选区，不能用字符数算光标（表名和字符串里可以有 emoji）。
public struct FormulaReferenceEdit: Equatable, Sendable {
    public private(set) var text: String
    public private(set) var span: NSRange
    public var caret: NSRange { NSRange(location: NSMaxRange(span), length: 0) }
    private let reference: ReferenceToken
    public var cells: CellRange { reference.range }
    public var sheet: String? { reference.sheet }

    private init(in text: String, replacing range: NSRange, reference: ReferenceToken, prefix: String) {
        let label = prefix + ReferenceShift.render(reference)
        self.text = (text as NSString).replacingCharacters(in: range, with: label)
        self.span = NSRange(location: range.location, length: label.utf16.count)
        self.reference = reference
    }

    private func isCurrent(in text: String, selection: NSRange) -> Bool {
        (selection == caret || selection == span) && ExactText(self.text) == ExactText(text)
    }

    /// 拾取引用期间若后台改过表名，旧草稿按旧表编号更新；刚点的引用已按当前页签生成，保留它并重定位光标。
    public mutating func rewriteSurroundingText(_ rewrite: (String) -> String) {
        let source = text as NSString
        let before = rewrite(source.substring(to: span.location))
        let after = rewrite(source.substring(from: NSMaxRange(span)))
        text = before + source.substring(with: span) + after
        span.location = before.utf16.count
    }

    /// 只有光标处能填操作数时，点击才属于公式。普通文字、字符串内部、已经打完的数值沿用原来的选格操作。
    public static func slot(in text: String, selection: NSRange, previous: Self?) -> NSRange? {
        guard text.hasPrefix("="), selection.location > 0, let range = Range(selection, in: text) else { return nil }
        if let previous, previous.isCurrent(in: text, selection: selection) { return previous.span }
        if let next = text[range.upperBound...].first(where: { !$0.isWhitespace }),
           !")+-*/^&%,:<>=;#}".contains(next) { return nil }
        let left = String(text[..<range.lowerBound])
        // 正在编辑的公式可以少一个右括号，也可以用引擎还不计算的函数、结构化引用。
        let tokens = (try? FormulaLexer.tokenize(left)) ?? ReferenceShift.maskingUnreadable(left).flatMap { try? FormulaLexer.tokenize($0) }
        switch tokens?.last?.kind {
        case .function, .openParen, .comma, .semicolon, .colon: return selection
        case .op(let symbol) where symbol != "%": return selection
        default: return nil
        }
    }

    public static func picking(_ cells: CellRange, sheet: String?, in text: String, selection: NSRange,
                               previous: Self?) -> Self? {
        guard let range = slot(in: text, selection: selection, previous: previous),
              case .reference(var reference)? = (try? FormulaLexer.tokenize(cells.label))?.first?.kind else { return nil }
        if let previous, previous.isCurrent(in: text, selection: selection) {
            reference.start.copyAnchors(from: previous.reference.start)
            reference.end?.copyAnchors(from: previous.reference.end ?? previous.reference.start)
        }
        reference.sheet = sheet
        var prefix = sheet.map { FormulaRewriter.quotedSheetName($0) + "!" } ?? ""
        if let sheet, range.location > 0 {
            let left = (text as NSString).substring(to: range.location)
            // 在另一张表先点 A1、打冒号、再点 A10，区域只在第一个端点写表名。
            if left.last == ":", let tokens = try? FormulaLexer.tokenize(left),
               case .reference(let start)? = tokens.dropLast().last?.kind,
               start.sheet?.caseInsensitiveCompare(sheet) == .orderedSame { prefix = "" }
            if left.last == "!", let tokens = try? FormulaLexer.tokenize(left + "A1"),
               case .reference(let qualified)? = tokens.last?.kind,
               qualified.sheet?.caseInsensitiveCompare(sheet) == .orderedSame { prefix = "" }
        }
        return Self(in: text, replacing: range, reference: reference, prefix: prefix)
    }

    /// F4 也能改手打的引用。只改光标/选区所在的引用，表名里原有的引号原样保留。
    public static func cyclingAnchors(in text: String, selection: NSRange) -> Self? {
        guard text.hasPrefix("="), let selected = Range(selection, in: text) else { return nil }
        var lexer = FormulaLexer(text)
        while let token = try? lexer.next() {
            guard case .reference(var reference) = token.kind,
                  token.range.lowerBound <= selected.lowerBound, selected.upperBound <= token.range.upperBound else { continue }
            reference.start.cycleAnchors()
            reference.end?.cycleAnchors()
            let original = text[token.range]
            let prefix = original.lastIndex(of: "!").map { String(original[...$0]) } ?? ""
            return Self(in: text, replacing: NSRange(token.range, in: text), reference: reference, prefix: prefix)
        }
        return nil
    }
}

private extension ReferencePoint {
    mutating func copyAnchors(from other: Self) {
        rowAbsolute = row != nil && other.rowAbsolute
        columnAbsolute = column != nil && other.columnAbsolute
    }

    mutating func cycleAnchors() {
        if column == nil { rowAbsolute.toggle() }
        else if row == nil { columnAbsolute.toggle() }
        else {
            switch (rowAbsolute, columnAbsolute) {
            case (false, false): (rowAbsolute, columnAbsolute) = (true, true)
            case (true, true): columnAbsolute = false
            case (true, false): (rowAbsolute, columnAbsolute) = (false, true)
            case (false, true): columnAbsolute = false
            }
        }
    }
}
