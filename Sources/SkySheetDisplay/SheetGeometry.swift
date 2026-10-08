import Foundation
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
    public let rowCount: Int
    public let columnCount: Int

    public static let pixelsPerPoint = 4.0 / 3.0

    public init(sheet: Sheet, baseFontSize: Double, digitWidth: Double = 7, zoom: Double = 1, minimumRows: Int = 100,
                minimumColumns: Int = 26) {
        self.zoom = zoom
        let digit = max(digitWidth, 1)
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

        let defaultRowPoints = sheet.defaultRowHeight ?? Self.defaultRowHeight(fontSize: baseFontSize)
        let defaultRow = defaultRowPoints * Self.pixelsPerPoint * zoom
        var rowOverrides: [Int: Double] = [:]
        for (row, format) in sheet.rowFormats where format.hidden || format.height != nil {
            rowOverrides[row] = format.hidden ? 0 : (format.height ?? defaultRowPoints) * Self.pixelsPerPoint * zoom
        }
        rows = AxisLayout(defaultSize: defaultRow, overrides: rowOverrides)

        let used = sheet.cells.usedRange
        let lastRow = max(used?.end.row ?? 0, sheet.frozen?.rows ?? 0, sheet.rowFormats.keys.max() ?? 0)
        rowCount = min(max(lastRow + 1 + 30, minimumRows), CellAddress.maxRows)
        let lastColumn = max(used?.end.column ?? 0, sheet.frozen?.columns ?? 0)
        columnCount = min(max(lastColumn + 1 + 8, minimumColumns), CellAddress.maxColumns)
    }

    /// Excel 的列宽单位（字符数，含边距）换成像素。`digitWidth` 是默认字体里数字的最大宽度。
    public static func columnPixels(_ width: Double, digitWidth: Double = 7) -> Double {
        ((256 * width + (128 / digitWidth).rounded(.down)) / 256 * digitWidth).rounded(.down)
    }

    /// 没写列宽时的默认列：8.43 个字符加 5 像素的边距和网格线（d = 7 时是 64 像素）。
    public static func defaultColumnPixels(digitWidth: Double = 7) -> Double {
        (8.43 * digitWidth).rounded(.down) + 5
    }

    /// 没写默认行高时按默认字号估：11 磅是 15 磅高，10 磅是 13.5 磅高（Excel 的默认值），四舍五入到 0.75 磅。
    public static func defaultRowHeight(fontSize: Double) -> Double {
        max(12.75, (fontSize * 1.36 / 0.75).rounded() * 0.75)
    }

    public var totalWidth: Double { columns.offset(columnCount) }
    public var totalHeight: Double { rows.offset(rowCount) }

    public func columnWidth(_ column: Int) -> Double { columns.size(column) }
    public func rowHeight(_ row: Int) -> Double { rows.size(row) }
    public func x(ofColumn column: Int) -> Double { columns.offset(column) }
    public func y(ofRow row: Int) -> Double { rows.offset(row) }
    public func column(atX x: Double) -> Int { columns.index(at: x, count: columnCount) }
    public func row(atY y: Double) -> Int { rows.index(at: y, count: rowCount) }

    /// 字号（磅）换成屏幕点。
    public func fontPoints(_ size: Double) -> Double { size * Self.pixelsPerPoint * zoom }
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
