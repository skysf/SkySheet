import Foundation
import CoreGraphics
import SkySheetCore

/// 一个方向上（行或者列）每一格多大、从哪开始。只记和默认大小不一样的那些（隐藏的算 0），
/// 位置靠「默认大小 × 序号 + 前面改过的差值之和」二分查出来：一百万行也不用一百万个数。
public struct AxisLayout: Sendable {
    public let defaultSize: Double
    private let overrideIndices: [Int]
    private let overrideSizes: [Double]
    /// prefix[k]：前 k 个改过的格子比默认多出来的总和。
    private let prefix: [Double]

    public init(defaultSize: Double, overrides: [Int: Double]) {
        self.defaultSize = defaultSize
        let sorted = overrides.sorted { $0.key < $1.key }
        overrideIndices = sorted.map(\.key)
        overrideSizes = sorted.map(\.value)
        var sums = [0.0]
        for size in overrideSizes { sums.append(sums.last! + size - defaultSize) }
        prefix = sums
    }

    public func size(_ index: Int) -> Double {
        let position = overrideIndices.lowerBound(of: index)
        return position < overrideIndices.count && overrideIndices[position] == index ? overrideSizes[position] : defaultSize
    }

    /// 第 `index` 格的起点（从第 0 格的起点算）。
    public func offset(_ index: Int) -> Double {
        Double(index) * defaultSize + prefix[overrideIndices.lowerBound(of: index)]
    }

    /// 落在 `position` 上的那一格（在 0..<count 里找；超出就是最后一格）。
    public func index(at position: Double, count: Int) -> Int {
        var low = 0
        var high = max(count - 1, 0)
        while low < high {
            let middle = (low + high + 1) / 2
            if offset(middle) <= position { low = middle } else { high = middle - 1 }
        }
        return low
    }
}

/// 一张表在屏幕上的行列大小（单位：屏幕点），以及可以滚动到多远（设计 8.2 节）。
///
/// 换算照 Excel 的定义：列宽 W 的单位是「默认字体里数字的最大宽度 d」，W → ⌊(256W + ⌊128/d⌋)/256 × d⌋ 像素，
/// 默认列 8.43 个字符（d = 7 时正好 64 像素）。d 要按我们真正用的字体量（App 量好传进来）：Mac 上替代「等线」的苹方，
/// 数字比 Windows 上宽，还按 7 算的话，Excel 里放得下的 ¥3,053.92 在我们这里变成 ###（2026-10-08 截图里 K 列就是）。
/// 行高 h（磅）→ h × 4/3 像素。屏幕点 = 像素 × 缩放比例。字号同样 × 4/3，比例和 Excel、腾讯文档一致。
public struct SheetGeometry: Sendable {
    public let columns: AxisLayout
    public let rows: AxisLayout
    public let zoom: Double
    /// 能滚动到的行数、列数：用到的范围再多留一些，至少铺满 `minimum`。
    public private(set) var rowCount: Int
    public private(set) var columnCount: Int
    /// 算这份几何时表里用到的范围（`sheet.cells.usedRange`）：下一份几何格子没变就接着用，不用再数一遍。
    public let usedRange: CellRange?
    /// 排两个方向用到的设置：下一份几何这个方向的设置一样，就接着用这里排好的（拖边线时每动一下都要重建几何，
    /// 十万行的表数一遍格子、排一遍行高要几十毫秒，2026-11-14）。
    private let columnInputs: ColumnInputs
    private let rowInputs: RowInputs
    /// 这份几何的两个方向是不是直接用的上一份（自检数它）。
    let reusedColumns: Bool
    let reusedRows: Bool

    private struct ColumnInputs: Equatable, Sendable {
        let formats: [ColumnFormat]
        let defaultWidth: Double?
        let digit: Double
        let zoom: Double
    }

    private struct RowInputs: Sendable {
        let formats: [Int: RowFormat]
        let defaultHeight: Double?
        let baseFontSize: Double
        let zoom: Double
        /// 设了格式的最后一行（能滚到哪要用），跟着 `formats` 定。
        let lastFormatted: Int
    }

    public static let pixelsPerPoint = 4.0 / 3.0

    public init(sheet: Sheet, baseFontSize: Double, digitWidth: Double = 7, zoom: Double = 1, minimumRows: Int = 100,
                minimumColumns: Int = 26) {
        self.init(sheet: sheet, baseFontSize: baseFontSize, digitWidth: digitWidth, zoom: zoom,
                  usedRange: sheet.cells.usedRange, reusing: nil, minimumRows: minimumRows, minimumColumns: minimumColumns)
    }

    /// `usedRange` 就是 `sheet.cells.usedRange`（调用方已经知道就直接给）；`previous` 是上一份几何：
    /// 某个方向的设置和它一样，就直接用它排好的那个方向。结果和从头算一模一样。
    public init(sheet: Sheet, baseFontSize: Double, digitWidth: Double, zoom: Double, usedRange: CellRange?,
                reusing previous: SheetGeometry?, minimumRows: Int = 100, minimumColumns: Int = 26) {
        self.zoom = zoom
        self.usedRange = usedRange
        let digit = max(digitWidth, 1)
        columnInputs = ColumnInputs(formats: sheet.columns, defaultWidth: sheet.defaultColumnWidth, digit: digit, zoom: zoom)
        reusedColumns = previous?.columnInputs == columnInputs
        if let previous, reusedColumns {
            columns = previous.columns
        } else {
            let defaultColumn = (sheet.defaultColumnWidth.map { Self.columnPixels($0, digitWidth: digit) }
                ?? Self.defaultColumnPixels(digitWidth: digit)) * zoom
            var columnOverrides: [Int: Double] = [:]
            for format in sheet.columns {
                let size = format.hidden ? 0
                    : (format.width.map { Self.columnPixels($0, digitWidth: digit) * zoom } ?? defaultColumn)
                for column in format.first...min(format.last, CellAddress.maxColumns - 1) {
                    columnOverrides[column] = size
                }
            }
            columns = AxisLayout(defaultSize: defaultColumn, overrides: columnOverrides)
        }

        let reusedRows = previous.flatMap { previous in
            previous.rowInputs.formats == sheet.rowFormats && previous.rowInputs.defaultHeight == sheet.defaultRowHeight
                && previous.rowInputs.baseFontSize == baseFontSize && previous.rowInputs.zoom == zoom ? previous : nil
        }
        self.reusedRows = reusedRows != nil
        if let reusedRows {
            rows = reusedRows.rows
            rowInputs = reusedRows.rowInputs
        } else {
            let defaultRowPoints = sheet.defaultRowHeight ?? Self.defaultRowHeight(fontSize: baseFontSize)
            let defaultRow = defaultRowPoints * Self.pixelsPerPoint * zoom
            var rowOverrides: [Int: Double] = [:]
            for (row, format) in sheet.rowFormats where format.hidden || format.height != nil {
                rowOverrides[row] = format.hidden ? 0 : (format.height ?? defaultRowPoints) * Self.pixelsPerPoint * zoom
            }
            rows = AxisLayout(defaultSize: defaultRow, overrides: rowOverrides)
            rowInputs = RowInputs(formats: sheet.rowFormats, defaultHeight: sheet.defaultRowHeight, baseFontSize: baseFontSize,
                                  zoom: zoom, lastFormatted: sheet.rowFormats.keys.max() ?? 0)
        }

        let lastRow = max(usedRange?.end.row ?? 0, sheet.frozen?.rows ?? 0, rowInputs.lastFormatted)
        rowCount = min(max(lastRow + 1 + 30, minimumRows), CellAddress.maxRows)
        let lastColumn = max(usedRange?.end.column ?? 0, sheet.frozen?.columns ?? 0)
        columnCount = min(max(lastColumn + 1 + 8, minimumColumns), CellAddress.maxColumns)
    }

    /// Excel 的列宽单位（字符数，含边距）换成像素。`digitWidth` 是默认字体里数字的最大宽度。
    public static func columnPixels(_ width: Double, digitWidth: Double = 7) -> Double {
        ((256 * width + (128 / digitWidth).rounded(.down)) / 256 * digitWidth).rounded(.down)
    }

    /// `columnPixels` 反过来：拖列标的边线拖到 `pixels` 宽（100% 缩放），存成多少个字符。按 Excel 的 1/256 个字符取，
    /// 往上取：再换回像素正好是这么宽，不会差一个像素（d 是任何值都成立：⌊128/d⌋·d/256 不到 0.5）。
    public static func columnWidth(forPixels pixels: Double, digitWidth: Double = 7) -> Double {
        let digit = max(digitWidth, 1)
        return (max(pixels.rounded(), 0) / digit * 256).rounded(.up) / 256
    }

    /// 拖行号的边线拖到 `pixels` 高（100% 缩放），存成多少磅：按 0.75 磅（Excel 的一个像素）取整。
    public static func rowHeight(forPixels pixels: Double) -> Double {
        (max(pixels, 0) / pixelsPerPoint / 0.75).rounded() * 0.75
    }

    /// 没写列宽时的默认列：8.43 个字符加 5 像素的边距和网格线（d = 7 时是 64 像素）。
    public static func defaultColumnPixels(digitWidth: Double = 7) -> Double {
        (8.43 * digitWidth).rounded(.down) + 5
    }

    /// 没写默认行高时按默认字号估（规则在 StyleTable.rowHeight(forFontSize:)，保存时也用它）。
    public static func defaultRowHeight(fontSize: Double) -> Double {
        StyleTable.rowHeight(forFontSize: fontSize)
    }

    public var totalWidth: Double { columns.offset(columnCount) }
    public var totalHeight: Double { rows.offset(rowCount) }

    /// 空白区域也可以导航；只扩展范围，不重新数格子或排行列，方向键在现有范围里时没有重建成本。
    @discardableResult
    public mutating func include(_ address: CellAddress) -> Bool {
        let oldRows = rowCount
        let oldColumns = columnCount
        if address.row >= rowCount { rowCount = min(address.row + 31, CellAddress.maxRows) }
        if address.column >= columnCount { columnCount = min(address.column + 9, CellAddress.maxColumns) }
        return rowCount != oldRows || columnCount != oldColumns
    }

    public func columnWidth(_ column: Int) -> Double { columns.size(column) }
    public func rowHeight(_ row: Int) -> Double { rows.size(row) }
    public func x(ofColumn column: Int) -> Double { columns.offset(column) }
    public func y(ofRow row: Int) -> Double { rows.offset(row) }

    /// 直接在这一帧持有的几何上算，避免每个格子为了四个坐标重复读取画布上的可变大结构。
    public func rect(of range: CellRange) -> CGRect {
        let left = x(ofColumn: range.start.column)
        let top = y(ofRow: range.start.row)
        return CGRect(x: left, y: top, width: x(ofColumn: range.end.column + 1) - left,
                      height: y(ofRow: range.end.row + 1) - top)
    }
    public func column(atX x: Double) -> Int { columns.index(at: x, count: columnCount) }
    public func row(atY y: Double) -> Int { rows.index(at: y, count: rowCount) }

    /// 字号（磅）换成屏幕点。
    public func fontPoints(_ size: Double) -> Double { size * Self.pixelsPerPoint * zoom }

    // MARK: - 局部重画（2026-11-14，设计 8.2 节「性能」）

    /// 一个格子画出来最多超出它的边多远（屏幕点）：填充往外 0.5；边框以「格线往里 0.5」为中心，最粗 3 磅 × 缩放；
    /// 选区框 2 点宽、以选区的边为中心；再加一个像素的抗锯齿。局部重画时，离重画范围这么近的格子都要一起画上。
    public var spill: Double { 1.5 + 1.5 * zoom }
}

extension [Int] {
    /// 第一个 ≥ value 的位置（数组从小到大排好）。
    func lowerBound(of value: Int) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            if self[middle] < value { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
