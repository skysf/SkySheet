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

    /// `shift` 对这个公式算得准不准。能切词的都准。切不了词的（结构化引用 `Table1[Amount]`、`[@Qty]`，外部引用
    /// `[1]Sheet1!A1`）`shift` 原样返回：方括号以外没有会跟着平移的引用时（`SUM(Table1[Amount])*$B$1`），原文就是
    /// 平移后的样子，也准；方括号以外还有 A1 这种相对引用就不准。只判断，不替它平移（读文件第 2 条，2026-11-16：
    /// 共享公式的主格切不了词时，跟随者不能拿原样返回的那份当自己的公式）。
    public static func isExact(_ formula: String) -> Bool {
        if (try? FormulaLexer.tokenize(formula)) != nil { return true }
        guard let masked = maskingBrackets(formula), (try? FormulaLexer.tokenize(masked)) != nil else { return false }
        return ExactText(shift(masked, rows: 1, columns: 1)) == ExactText(masked)
    }

    /// 方括号整段（连同里面套着的方括号）换成一个数字：结构化引用、外部引用的那一截。引号里的字、引号括起来的 sheet 名
    /// 原样；方括号里 ' 转义下一个字符（Excel 的写法，`Table1['[x']]`）。括号、引号不配对返回 nil。
    static func maskingBrackets(_ formula: String) -> String? {
        var result = String.UnicodeScalarView()
        var depth = 0
        var quote: Unicode.Scalar?
        var scalars = formula.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            if depth > 0 {
                switch scalar {
                case "'": guard scalars.next() != nil else { return nil }
                case "[": depth += 1
                case "]":
                    depth -= 1
                    if depth == 0 { result.append(contentsOf: " 0 ".unicodeScalars) }
                default: break
                }
                continue
            }
            if let open = quote {
                // "" 和 '' 是转义：这一段到这里结束，紧接着的引号又开一段，效果一样。
                if scalar == open { quote = nil }
                result.append(scalar)
                continue
            }
            switch scalar {
            case "\"", "'":
                quote = scalar
                result.append(scalar)
            case "[": depth = 1
            case "]": return nil
            default: result.append(scalar)
            }
        }
        return depth == 0 && quote == nil ? String(result) : nil
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
