import Foundation

/// 表格块 → SQL 的表（设计 9.2 节 query）。每张表多一列 `_row`：那条记录在 sheet 里是第几行，AI 好写指向它的公式。
/// 日期写成 'YYYY-MM-DD' 的文字（比较、筛选按文字就对），数字是浮点数，逻辑值是 0 / 1，错误写成错误码。
public enum QueryTables {
    /// 整本的表：每张 sheet 认出来的块，加上 `extra` 里点名的区域（第一行是表头）。
    public static func tables(for workbook: Workbook, extra: [(name: String, sheet: Int, range: CellRange)] = []) -> [SQLQuery.Table] {
        var tables: [SQLQuery.Table] = []
        for sheet in workbook.sheets {
            for block in TableBlocks.find(in: sheet) {
                tables.append(table(block, in: sheet, dateSystem: workbook.dateSystem, styles: workbook.styles))
            }
        }
        for item in extra where workbook.sheets.indices.contains(item.sheet) {
            let sheet = workbook.sheets[item.sheet]
            let block = TableBlocks.block(item.range, named: item.name, in: sheet)
            tables.removeAll { $0.name.caseInsensitiveCompare(item.name) == .orderedSame }
            tables.append(table(block, in: sheet, dateSystem: workbook.dateSystem, styles: workbook.styles))
        }
        return tables
    }

    static func table(_ block: TableBlock, in sheet: Sheet, dateSystem: DateSystem, styles: StyleTable) -> SQLQuery.Table {
        let rows = block.dataRows.map { Array($0) } ?? []
        return SQLQuery.Table(
            name: block.name, columns: ["_row"] + block.columns.map(\.name),
            rows: rows.map { row in
                [.integer(Int64(row + 1))] + block.columns.map { column in
                    value(sheet.cells[row, column.index], styles: styles, dateSystem: dateSystem)
                }
            })
    }

    static func value(_ cell: Cell?, styles: StyleTable, dateSystem: DateSystem) -> SQLQuery.Value {
        guard let cell else { return .null }
        switch cell.value {
        case .empty: return .null
        case .text(let text): return .text(text)
        case .bool(let flag): return .integer(flag ? 1 : 0)
        case .error(let error): return .text(error.code)
        case .number(let number):
            if ValueFormatter.isDateFormat(styles.formatCode(forStyle: cell.styleIndex)),
               let iso = DateSerial.isoText(number, system: dateSystem) {
                return .text(iso)
            }
            return .real(DecimalMath.double(number))
        }
    }
}
