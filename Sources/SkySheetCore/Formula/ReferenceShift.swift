import Foundation

/// 平移公式里的相对引用。引用平移只有这一份（设计 5.1 节）：展开 xlsx 的共享公式、复制粘贴、复制 sheet、
/// AI 的「往下填充」都用它。
public enum ReferenceShift {
    /// 把相对引用平移 `rows` 行、`columns` 列；带 $ 的部分不动。移出表格的引用变成 #REF!，和 Excel 一样。
    /// 只改引用，其余字符（空格、函数名大小写、字符串里的 "A1"）原样保留。切不了词的公式原样返回。
    public static func shift(_ formula: String, rows: Int, columns: Int) -> String {
        guard rows != 0 || columns != 0, let tokens = try? FormulaLexer.tokenize(formula) else { return formula }
        var result = ""
        var cursor = formula.startIndex
        for token in tokens {
            guard case .reference(let reference) = token.kind else { continue }
            result += formula[cursor..<token.range.lowerBound]
            let original = formula[token.range]
            // sheet 前缀（到最后一个 "!" 为止）原样保留，只重写后面的引用。
            let prefix = reference.sheet == nil ? "" : String(original[...original.lastIndex(of: "!")!])
            result += prefix + (shifted(reference, rows: rows, columns: columns) ?? "#REF!")
            cursor = token.range.upperBound
        }
        result += formula[cursor...]
        return result
    }

    /// `shift` 对这个公式算得准不准。能切词的都准。切不了词的 `shift` 原样返回：把和平移无关、词法又读不了的几样盖掉
    /// （maskingUnreadable）以后，没有会跟着平移的引用（`SUM(Table1[Amount])*$B$1`、`Sheet1!Rate*2`、`$A$1#`），原文就是
    /// 平移后的样子，也准；还有 A1 这种相对引用（`A1+SUM(Table1[Amount])`），或者盖掉以后仍切不了词，就不准。
    /// 只判断，不替它平移（读文件第 2 条，2026-11-16：共享公式的主格切不了词时，跟随者不能拿原样返回的那份当自己的公式；
    /// PR #17 第一轮审查第 2 条：带 sheet 名的定义名称、绝对引用的溢出区这类，main 给的原文本来就对，不能留空）。
    public static func isExact(_ formula: String) -> Bool {
        if (try? FormulaLexer.tokenize(formula)) != nil { return true }
        guard let masked = maskingUnreadable(formula), let tokens = try? FormulaLexer.tokenize(masked) else { return false }
        // 看引用动不动，不比平移前后写出来的字：平移会把 `$a$1` 写成 `$A$1`，引用并没有动（PR #17 第二轮审查第 1 条）。
        return !tokens.contains { token in
            guard case .reference(let reference) = token.kind else { return false }
            return moves(reference)
        }
    }

    /// 平移的时候这个引用会不会动：起点、终点里有相对的行或列就会（和 `move` 同一个规矩）。
    private static func moves(_ reference: ReferenceToken) -> Bool {
        let points = [reference.start] + (reference.end.map { [$0] } ?? [])
        return points.contains { ($0.row != nil && !$0.rowAbsolute) || ($0.column != nil && !$0.columnAbsolute) }
    }

    /// 切不了词的公式里，和平移无关、词法又读不了的几样换成空白，剩下的才能切词：方括号整段（结构化引用 `Table1[Amount]`、
    /// `[@Qty]`，外部引用的 `[1]`，换成一个数字）、sheet 名前缀（`Sheet1!`、`'Q 1'!`：后面是定义名称时词法读不了，
    /// 是引用的话引用本身留着）、动态数组的溢出符 `#` 和 `@`。字符串、错误值（`#REF!`）原样；方括号里 ' 转义下一个字符
    /// （Excel 的写法，`Table1['[x']]`）。括号、引号不配对返回 nil。
    static func maskingUnreadable(_ formula: String) -> String? {
        let scalars = Array(formula.unicodeScalars)
        var result = String.UnicodeScalarView()
        func blank(_ count: Int) { result.append(contentsOf: repeatElement(" " as Unicode.Scalar, count: count)) }
        /// 从 `start` 的引号到配对的那个引号（两个连着的是转义，算一个字）。
        func closing(_ quote: Unicode.Scalar, from start: Int) -> Int? {
            var index = start + 1
            while index < scalars.count {
                guard scalars[index] == quote else { index += 1; continue }
                guard index + 1 < scalars.count, scalars[index + 1] == quote else { return index }
                index += 2
            }
            return nil
        }
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar {
            case "\"":
                guard let end = closing(scalar, from: index) else { return nil }
                result.append(contentsOf: scalars[index...end])
                index = end + 1
            case "'":
                guard let end = closing(scalar, from: index) else { return nil }
                if end + 1 < scalars.count, scalars[end + 1] == "!" {
                    blank(end + 2 - index)
                    index = end + 2
                } else {
                    result.append(contentsOf: scalars[index...end])
                    index = end + 1
                }
            case "[":
                var depth = 0
                var end = index
                while end < scalars.count {
                    switch scalars[end] {
                    case "'" where depth > 0: end += 1
                    case "[": depth += 1
                    case "]": depth -= 1
                    default: break
                    }
                    if depth == 0 { break }
                    end += 1
                }
                guard end < scalars.count, depth == 0 else { return nil }
                result.append(contentsOf: " 0 ".unicodeScalars)
                index = end + 1
            case "]":
                return nil
            case "#":
                let rest = String(String.UnicodeScalarView(scalars[index...].prefix(16))).uppercased()
                if let code = FormulaLexer.errorCodes.first(where: { rest.hasPrefix($0) }) {
                    let count = code.unicodeScalars.count
                    result.append(contentsOf: scalars[index..<(index + count)])
                    index += count
                } else {
                    blank(1)
                    index += 1
                }
            case "@":
                blank(1)
                index += 1
            default:
                guard FormulaLexer.isIdentifierStart(scalar),
                      index == 0 || !FormulaLexer.isIdentifierContinue(scalars[index - 1]) else {
                    result.append(scalar)
                    index += 1
                    continue
                }
                var end = index
                while end < scalars.count, FormulaLexer.isIdentifierContinue(scalars[end]) { end += 1 }
                if end < scalars.count, scalars[end] == "!" {
                    blank(end + 1 - index)
                    index = end + 1
                } else {
                    result.append(contentsOf: scalars[index..<end])
                    index = end
                }
            }
        }
        return String(result)
    }

    private static func shifted(_ reference: ReferenceToken, rows: Int, columns: Int) -> String? {
        guard let start = move(reference.start, rows, columns) else { return nil }
        guard let end = reference.end else { return render(start) }
        guard let movedEnd = move(end, rows, columns) else { return nil }
        return render(start) + ":" + render(movedEnd)
    }

    private static func move(_ point: ReferencePoint, _ rows: Int, _ columns: Int) -> ReferencePoint? {
        var moved = point
        if let row = point.row, !point.rowAbsolute {
            guard (0..<CellAddress.maxRows).contains(row + rows) else { return nil }
            moved.row = row + rows
        }
        if let column = point.column, !point.columnAbsolute {
            guard (0..<CellAddress.maxColumns).contains(column + columns) else { return nil }
            moved.column = column + columns
        }
        return moved
    }

    /// 一个引用的写法（不带 sheet 名）：单格 "B$3"，区域 "A1:C9"，整列 "A:C"，整行 "3:5"。插删行列改引用时也用它。
    static func render(_ reference: ReferenceToken) -> String {
        render(reference.start) + (reference.end.map { ":" + render($0) } ?? "")
    }

    private static func render(_ point: ReferencePoint) -> String {
        var text = ""
        if let column = point.column {
            text += (point.columnAbsolute ? "$" : "") + CellAddress.columnName(column)
        }
        if let row = point.row {
            text += (point.rowAbsolute ? "$" : "") + String(row + 1)
        }
        return text
    }
}
