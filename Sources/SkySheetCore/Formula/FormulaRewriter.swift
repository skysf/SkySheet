import Foundation

/// 公式原文的改写：sheet 改名、删 sheet、写进文件时的写法。和 ReferenceShift 一样按词改，别的字符一个不动。
public enum FormulaRewriter {
    /// sheet 改名后，指向旧名字的引用换成新名字（要加引号的自动加）。sheet 名不分大小写，和 Excel 一样。
    public static func renameSheet(in formula: String, from old: String, to new: String) -> String {
        rewriteReferences(in: formula) { reference, original in
            guard let sheet = reference.sheet, sheet.caseInsensitiveCompare(old) == .orderedSame else { return nil }
            return quotedSheetName(new) + "!" + String(original[original.index(after: original.lastIndex(of: "!")!)...])
        }
    }

    /// sheet 删掉后，指向它的引用变成 #REF!（Excel 也这样：=Loan!A1 变成 =#REF!）。
    public static func removeSheet(in formula: String, named name: String) -> String {
        rewriteReferences(in: formula) { reference, _ in
            guard let sheet = reference.sheet, sheet.caseInsensitiveCompare(name) == .orderedSame else { return nil }
            return "#REF!"
        }
    }

    /// 写进 xlsx 的写法：不带开头的 "="；Excel 2010 以后才有的函数加上 `_xlfn.` 前缀，不加的话 Excel 打开是 #NAME?。
    public static func storageForm(_ formula: String) -> String {
        let text = formula.hasPrefix("=") ? String(formula.dropFirst()) : formula
        guard let tokens = try? FormulaLexer.tokenize(text) else { return text }
        var result = ""
        var cursor = text.startIndex
        for token in tokens {
            guard case .function(let name) = token.kind,
                  prefixedFunctions.contains(FormulaParser.canonicalFunctionName(name)),
                  !name.uppercased().hasPrefix("_XLFN.") else { continue }
            result += text[cursor..<token.range.lowerBound] + "_xlfn."
            cursor = token.range.lowerBound
        }
        return result + text[cursor...]
    }

    /// 我们支持的函数里，Excel 存文件时要加 `_xlfn.` 的那些（Excel 2010 以后新加的）。
    static let prefixedFunctions: Set<String> = ["CONCAT", "IFS", "XLOOKUP", "DAYS", "RANK.EQ"]

    /// 公式里写 sheet 名：只有字母、数字、下划线、中文，而且不像格子地址、不以数字开头的，可以不加引号；
    /// 其余加单引号，名字里的单引号写两个。
    public static func quotedSheetName(_ name: String) -> String {
        let plain = !name.isEmpty
            && name.unicodeScalars.allSatisfy { FormulaLexer.isIdentifierContinue($0) && $0 != "." }
            && !FormulaLexer.isDigit(name.unicodeScalars.first!)
            && CellAddress(a1: name) == nil
            && !["TRUE", "FALSE"].contains(name.uppercased())
        return plain ? name : "'" + name.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// 逐个引用问 `replacement`：返回 nil 表示不改，否则用返回的文字替换这个引用的原文（含 sheet 前缀）。
    private static func rewriteReferences(in formula: String,
                                          _ replacement: (ReferenceToken, Substring) -> String?) -> String {
        guard let tokens = try? FormulaLexer.tokenize(formula) else { return formula }
        var result = ""
        var cursor = formula.startIndex
        for token in tokens {
            guard case .reference(let reference) = token.kind,
                  let replaced = replacement(reference, formula[token.range]) else { continue }
            result += formula[cursor..<token.range.lowerBound] + replaced
            cursor = token.range.upperBound
        }
        return result + formula[cursor...]
    }
}

/// sheet 名的规矩（Excel 的）：1–31 个字符；不能有 : \ / ? * [ ]；不能以单引号开头或结尾；不能叫 History；不能和别的重名（不分大小写）。
public enum SheetName {
    public enum Problem: Error, Equatable, Sendable {
        case empty
        case tooLong
        case invalidCharacter(Character)
        case apostropheAtEdge
        case reserved
        case duplicate
    }

    public static let maxLength = 31

    public static func problem(with name: String, among existing: [String], ignoring index: Int? = nil) -> Problem? {
        guard !name.isEmpty else { return .empty }
        guard name.count <= maxLength else { return .tooLong }
        if let bad = name.first(where: { ":\\/?*[]".contains($0) }) { return .invalidCharacter(bad) }
        if name.hasPrefix("'") || name.hasSuffix("'") { return .apostropheAtEdge }
        if name.caseInsensitiveCompare("History") == .orderedSame { return .reserved }
        for (position, other) in existing.enumerated() where position != index {
            if other.caseInsensitiveCompare(name) == .orderedSame { return .duplicate }
        }
        return nil
    }

    /// 复制 sheet 时的新名字：「Loan (2)」「Loan (3)」……超长就截短前面的部分。
    public static func copyName(of name: String, among existing: [String]) -> String {
        for number in 2... {
            let suffix = " (\(number))"
            let candidate = String(name.prefix(maxLength - suffix.count)) + suffix
            if problem(with: candidate, among: existing) == nil { return candidate }
        }
        return name
    }
}
