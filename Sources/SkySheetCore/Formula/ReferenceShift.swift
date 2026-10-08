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
