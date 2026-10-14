import Foundation

/// 行高、列宽、隐藏行列、冻结窗格（设计第 16 条，2026-10-14 加的版式编辑）。界面上拖列标行号的边线、菜单、AI 的
/// edit_rows_columns 都用这一份。只改版式，不碰格子和公式。
extension Sheet {
    /// 改一段列的格式。xlsx 的 `<col>` 是一段一段记的：改其中几列，先把原来的段在边上拆开，改完再把挨着、一样的并起来。
    /// 中间原来没写格式的列从默认的开始改。整张表 16,384 列也只按段算，不一列一列走。
    public mutating func updateColumns(_ span: ClosedRange<Int>, _ change: (inout ColumnFormat) -> Void) {
        let span = max(span.lowerBound, 0)...min(span.upperBound, CellAddress.maxColumns - 1)
        var result: [ColumnFormat] = []
        var cursor = span.lowerBound
        for format in columns.sorted(by: { $0.first < $1.first }) {
            guard format.last >= span.lowerBound, format.first <= span.upperBound else {
                result.append(format)
                continue
            }
            if format.first < span.lowerBound {
                var before = format
                before.last = span.lowerBound - 1
                result.append(before)
            }
            if format.last > span.upperBound {
                var after = format
                after.first = span.upperBound + 1
                result.append(after)
            }
            let lower = max(format.first, span.lowerBound)
            if cursor < lower {
                var gap = ColumnFormat(first: cursor, last: lower - 1)
                change(&gap)
                result.append(gap)
            }
            var part = format
            part.first = lower
            part.last = min(format.last, span.upperBound)
            change(&part)
            result.append(part)
            cursor = part.last + 1
        }
        if cursor <= span.upperBound {
            var gap = ColumnFormat(first: cursor, last: span.upperBound)
            change(&gap)
            result.append(gap)
        }
        columns = Self.normalized(result)
    }

    /// 从小到大排好；什么都没设的段去掉；挨着、一样的段并成一段。
    static func normalized(_ formats: [ColumnFormat]) -> [ColumnFormat] {
        var merged: [ColumnFormat] = []
        for format in formats.sorted(by: { $0.first < $1.first })
        where format.width != nil || format.hidden || format.styleIndex != nil {
            if var last = merged.last, last.last + 1 == format.first, last.width == format.width,
               last.hidden == format.hidden, last.styleIndex == format.styleIndex {
                last.last = format.last
                merged[merged.count - 1] = last
            } else {
                merged.append(format)
            }
        }
        return merged
    }

    /// 改几行的格式；改完和默认一样（没有行高、没隐藏、没样式）的行不再记。调用方先把行数限制在合理的范围里。
    public mutating func updateRows(_ span: ClosedRange<Int>, _ change: (inout RowFormat) -> Void) {
        let span = max(span.lowerBound, 0)...min(span.upperBound, CellAddress.maxRows - 1)
        for row in span {
            var format = rowFormats[row] ?? RowFormat()
            change(&format)
            rowFormats[row] = format == RowFormat() ? nil : format
        }
    }

    /// 列宽（Excel 的字符数）；nil 是回到默认列宽。隐藏、样式留着。
    public mutating func setColumnWidth(_ width: Double?, columns span: ClosedRange<Int>) {
        updateColumns(span) { $0.width = width }
    }

    /// 行高（磅）；nil 是回到默认行高。隐藏、样式留着。
    public mutating func setRowHeight(_ height: Double?, rows span: ClosedRange<Int>) {
        updateRows(span) { $0.height = height }
    }

    /// 隐藏或取消隐藏几行（列）。宽度、高度留着，取消隐藏时回到原来的大小。
    public mutating func setHidden(_ hidden: Bool, _ axis: SheetAxis, _ span: ClosedRange<Int>) {
        switch axis {
        case .rows: updateRows(span) { $0.hidden = hidden }
        case .columns: updateColumns(span) { $0.hidden = hidden }
        }
    }

    /// 这一行（列）是不是隐藏的。
    public func isHidden(_ axis: SheetAxis, _ index: Int) -> Bool {
        switch axis {
        case .rows: rowFormats[index]?.hidden ?? false
        case .columns: columns.contains { $0.hidden && ($0.first...$0.last).contains(index) }
        }
    }

    /// 这一段里藏着的行（列）。
    public func hiddenLines(_ axis: SheetAxis, in span: ClosedRange<Int>) -> [Int] {
        switch axis {
        case .rows:
            return rowFormats.filter { $0.value.hidden && span.contains($0.key) }.keys.sorted()
        case .columns:
            return columns.filter(\.hidden).flatMap { format -> [Int] in
                let lower = max(format.first, span.lowerBound)
                let upper = min(format.last, span.upperBound)
                return lower <= upper ? Array(lower...upper) : []
            }.sorted()
        }
    }

    /// 冻结上面 `rows` 行、左边 `columns` 列；都是 0 就是不冻结。
    public mutating func freeze(rows: Int, columns: Int) {
        frozen = rows > 0 || columns > 0 ? FrozenPanes(rows: rows, columns: columns) : nil
    }
}

extension Workbook {
    /// 设几列的列宽（Excel 的字符数，nil 是默认宽度）。这几列原来的隐藏、样式留着；挨着、设得一样的列并成一段。
    public mutating func setColumnWidth(_ width: Double?, columns: ClosedRange<Int>, sheet index: Int) {
        sheets[index].setColumnWidth(width, columns: columns)
    }

    /// 设几行的行高（磅，nil 是默认行高）。
    public mutating func setRowHeight(_ height: Double?, rows: ClosedRange<Int>, sheet index: Int) {
        sheets[index].setRowHeight(height, rows: rows)
    }

    public mutating func setHidden(_ hidden: Bool, _ axis: SheetAxis, _ lines: ClosedRange<Int>, sheet index: Int) {
        sheets[index].setHidden(hidden, axis, lines)
    }

    /// 冻结上面 `rows` 行、左边 `columns` 列；都是 0 就是不冻结。
    public mutating func freeze(rows: Int, columns: Int, sheet index: Int) {
        sheets[index].freeze(rows: rows, columns: columns)
    }
}
