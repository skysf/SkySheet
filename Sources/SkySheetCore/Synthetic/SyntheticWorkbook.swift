import Foundation

/// 测速和性能自检用的合成大表格（2026-11-14，设计 8.2 节「性能」）。大的二进制文件不进仓库，要用时现造；
/// App 的测速模式（`SkySheet --benchmark synthetic:data`）和 SkySheetChecks 用的是同一份，数字才对得上。
/// 每本都多带一张小表「Notes」：量「换 sheet」要有地方可换。数据用固定种子的伪随机数，每次造出来一模一样。
public enum SyntheticWorkbook: String, CaseIterable, Sendable {
    /// 10 万行 × 20 列纯数据（没有公式）：日期、文字、各种数字格式，冻结首行首列。
    case data
    /// 一万期等额本息还款计划表：5 万个公式，每行引用上一行，依赖链一万层深（设计 5.5 节那张）。
    case formulas
    /// 5,000 行 × 26 列：几千个合并单元格、各种填充 / 边框 / 字体、自动换行、往旁边溢出的长文字、改过的行高、
    /// 藏起来的行列，冻结两行一列。
    case styles

    public func make(scale: Double = 1) -> Workbook {
        switch self {
        case .data: Self.data(rows: Self.scaled(100_000, scale))
        case .formulas: Self.formulas(periods: Self.scaled(10_000, scale))
        case .styles: Self.styles(blocks: Self.scaled(500, scale))
        }
    }

    private static func scaled(_ count: Int, _ scale: Double) -> Int {
        max(1, Int((Double(count) * scale).rounded()))
    }

    // MARK: - 10 万行纯数据

    /// `rows` 行数据加一行表头，20 列。
    public static func data(rows: Int) -> Workbook {
        var styles = StyleTable()
        styles.customNumberFormats = [164: "\"¥\"#,##0.00_);[Red](\"¥\"#,##0.00)"]
        styles.fonts.append(FontStyle(bold: true))
        styles.cellFormats = [
            CellFormat(),                                            // 0 常规
            CellFormat(numberFormatID: 14),                          // 1 日期
            CellFormat(numberFormatID: 4),                           // 2 #,##0.00
            CellFormat(numberFormatID: 10),                          // 3 0.00%
            CellFormat(numberFormatID: 164),                         // 4 人民币
            CellFormat(fontID: 1, horizontalAlignment: "center"),    // 5 表头
        ]
        var sheet = Sheet(id: 1, name: "Data")
        sheet.frozen = FrozenPanes(rows: 1, columns: 1)
        let titles = ["Date", "Region", "Note", "Quantity", "Price", "Amount", "Rate", "Balance", "Score", "Count",
                      "Fee", "Tax", "Net", "Share", "Index", "Cost", "Margin", "Days", "Ratio", "Total"]
        for (column, title) in titles.enumerated() {
            sheet.cells[0, column] = Cell(value: .text(title), styleIndex: 5)
        }
        var random = SeededRandom(seed: 20261114)
        for row in 1...max(rows, 1) {
            sheet.cells[row, 0] = Cell(value: .number(Decimal(45_000 + row / 40)), styleIndex: 1)
            sheet.cells[row, 1] = Cell(value: .text("Region \(random.next(37))"))
            // 长短不一的备注：长的比列宽长，右边是数字、溢不出去，画的时候要判断。
            let note = random.next(5) == 0 ? "Order \(row) – follow up with the customer next week" : "Order \(row)"
            sheet.cells[row, 2] = Cell(value: .text(note))
            for column in 3..<20 {
                let cents = Decimal(random.next(10_000_000)) - 1_000_000
                let (value, style): (Decimal, Int) = switch column % 5 {
                case 0: (Decimal(random.next(1000)), 0)               // 整数
                case 1: (cents / 100, 2)                              // 金额 #,##0.00
                case 2: (Decimal(random.next(100_000)) / 1_000_000, 3)  // 百分比
                case 3: (cents / 100, 4)                              // 人民币
                default: (cents / 1000, 0)                            // 常规小数
                }
                sheet.cells[row, column] = Cell(value: .number(value), styleIndex: style)
            }
        }
        return Workbook(sheets: [sheet, notes(id: 2)], styles: styles)
    }

    // MARK: - 一万期还款计划表

    /// 每期利率 0.01%。别用 0.25%：一万期的话 1.0025^10000 ≈ 7e10，PMT 在第 16 位上的舍入误差会被放大三十万亿倍，
    /// 期末余额差出几块钱（2026-10-08 实测 -7.70）。那是这种长链本身的病态，Excel 一样；30 年房贷只放大 584 倍。
    public static func formulas(periods: Int) -> Workbook {
        var styles = StyleTable()
        styles.cellFormats = [CellFormat(), CellFormat(numberFormatID: 4)]
        var sheet = Sheet(id: 1, name: "Schedule")
        func put(_ a1: String, _ cell: Cell) { sheet.cells[CellAddress(a1: a1)!] = cell }
        put("H1", Cell(value: .number(Decimal(string: "0.0001")!)))
        put("H2", Cell(formula: CellFormula(source: "PMT(H1,\(periods),-1000000)"), styleIndex: 1))
        for row in 1...max(periods, 1) {
            put("A\(row)", Cell(value: .number(Decimal(row))))
            // 期初余额 = 上一期的期末余额
            put("B\(row)", row == 1 ? Cell(value: .number(1_000_000), styleIndex: 1)
                                    : Cell(formula: CellFormula(source: "F\(row - 1)"), styleIndex: 1))
            put("C\(row)", Cell(formula: CellFormula(source: "B\(row)*$H$1"), styleIndex: 1))   // 利息
            put("D\(row)", Cell(formula: CellFormula(source: "$H$2"), styleIndex: 1))           // 每期还款
            put("E\(row)", Cell(formula: CellFormula(source: "D\(row)-C\(row)"), styleIndex: 1)) // 本金
            put("F\(row)", Cell(formula: CellFormula(source: "B\(row)-E\(row)"), styleIndex: 1)) // 期末余额
        }
        return Workbook(sheets: [sheet, notes(id: 2)], styles: styles)
    }

    // MARK: - 合并单元格和样式

    /// 每 10 行一段：第一行是整行合并的小标题（底色、粗体、居中、行高 24 磅）；下面 9 行里 B 列每 3 行竖着合并一次，
    /// G:H 每行横着合并。500 段就是 6,500 个合并单元格。格子带着轮换的底色、细边框、粗斜体、居中；E 列自动换行；
    /// X 列是比列宽长得多的文字，右边空着，往外溢。每 50 行藏一行，藏起 W 列。
    public static func styles(blocks: Int) -> Workbook {
        var styles = StyleTable()
        let thin = BorderEdge(style: "thin", color: StyleColor(.rgb("FFBFBFBF")))
        styles.borders.append(BorderStyle(left: thin, right: thin, top: thin, bottom: thin))   // 1
        styles.fonts.append(FontStyle(bold: true))                                            // 1
        styles.fonts.append(FontStyle(italic: true, color: StyleColor(.rgb("FF7030A0"))))       // 2
        let palette = ["FFFFF2CC", "FFFCE4D6", "FFFFC7CE", "FFE2EFDA", "FFDDEBF7", "FFE4DFEC", "FFF2F2F2", "FFFFFF00"]
        for color in palette {
            styles.fills.append(FillStyle(pattern: "solid", foreground: StyleColor(.rgb(color))))
        }
        var formats = [CellFormat()]
        // 1…8：小标题，各一种底色。
        for fill in 0..<palette.count {
            formats.append(CellFormat(fontID: 1, fillID: 2 + fill, borderID: 1, horizontalAlignment: "center",
                                      verticalAlignment: "center"))
        }
        // 9…：正文，底色 × 字体 × 对齐轮换。
        let bodyStart = formats.count
        for fill in 0...palette.count {
            for font in 0..<3 {
                formats.append(CellFormat(numberFormatID: font == 0 ? 4 : 0, fontID: font,
                                          fillID: fill == palette.count ? 0 : 2 + fill, borderID: 1,
                                          horizontalAlignment: font == 2 ? "center" : nil))
            }
        }
        let bodyCount = formats.count - bodyStart
        let wrap = formats.count
        formats.append(CellFormat(borderID: 1, verticalAlignment: "top", wrapText: true))
        styles.cellFormats = formats

        var sheet = Sheet(id: 1, name: "Styled")
        sheet.frozen = FrozenPanes(rows: 2, columns: 1)
        sheet.setColumnWidth(18, columns: 4...4)
        sheet.setHidden(true, .columns, 22...22)
        var random = SeededRandom(seed: 1114)
        let columns = 26
        for block in 0..<max(blocks, 1) {
            let top = block * 10
            sheet.cells[top, 0] = Cell(value: .text("Section \(block + 1)"), styleIndex: 1 + block % palette.count)
            sheet.merges.append(CellRange(CellAddress(row: top, column: 0), CellAddress(row: top, column: columns - 1)))
            sheet.rowFormats[top] = RowFormat(height: 24)
            for offset in 1..<10 {
                let row = top + offset
                for column in 0..<columns where column != 23 && column != 24 && column != 25 {
                    let style = bodyStart + random.next(bodyCount)
                    // 合并单元格里左上角以外的格子只有样式没有值（和 Excel、腾讯文档存出来的一样）。
                    let covered = column == 7 || (column == 1 && offset % 3 != 1)
                    let value: CellValue = covered ? .empty
                        : column <= 1 ? .text("Item \(row)-\(column)") : .number(Decimal(random.next(10_000_000)) / 100)
                    sheet.cells[row, column] = Cell(value: value, styleIndex: style)
                }
                sheet.cells[row, 4] = Cell(value: .text("Wrapped text that needs two lines \(row)"), styleIndex: wrap)
                sheet.cells[row, 23] = Cell(value: .text("A long note that runs over the empty cells to its right, row \(row)"))
                sheet.merges.append(CellRange(CellAddress(row: row, column: 6), CellAddress(row: row, column: 7)))
                if offset % 3 == 1 {
                    sheet.merges.append(CellRange(CellAddress(row: row, column: 1), CellAddress(row: row + 2, column: 1)))
                }
                if row % 50 == 25 { sheet.rowFormats[row] = RowFormat(hidden: true) }
            }
        }
        return Workbook(sheets: [sheet, notes(id: 2)], styles: styles)
    }

    // MARK: -

    /// 一张小表，量「换 sheet」用。
    private static func notes(id: Int) -> Sheet {
        var sheet = Sheet(id: id, name: "Notes")
        for row in 0..<20 {
            sheet.cells[row, 0] = Cell(value: .text("Note \(row + 1)"))
            sheet.cells[row, 1] = Cell(value: .number(Decimal(row * 100)))
        }
        return sheet
    }
}

/// 固定种子的伪随机数（线性同余）：合成的表每次一模一样，测出来的数字前后可比。
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    /// 0..<bound 里的一个数。
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(max(bound, 1)))
    }
}
