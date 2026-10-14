import Foundation

/// 改格子的样子：数字格式、粗体、斜体、字的颜色、底色、对齐、自动换行（设计 9.2 节 format_cells；2026-10-14 起界面上的
/// Format 菜单也用这一份）。样式表只往后加（设计 7.2 节），同样的组合复用同一个编号。
extension Workbook {
    /// 一次样式修改：只改给了的几样。
    public struct CellStyleChange: Sendable, Equatable {
        /// 颜色：ARGB 十六进制（如 "FFC00000"），或者「自动」：字回到默认颜色、底色不填。
        public enum Color: Sendable, Equatable {
            case automatic
            case rgb(String)
        }

        /// 水平对齐。general 是「常规」：数字靠右、文字靠左（Excel 的默认）。
        public enum Horizontal: String, CaseIterable, Sendable {
            case general, left, center, right
        }

        /// 垂直对齐。bottom 是 Excel 的默认。
        public enum Vertical: String, CaseIterable, Sendable {
            case top, center, bottom
        }

        /// 数字格式代码（预设先换成代码再传进来）。
        public var numberFormat: String?
        public var bold: Bool?
        public var italic: Bool?
        public var fontColor: Color?
        public var fillColor: Color?
        public var horizontal: Horizontal?
        public var vertical: Vertical?
        public var wrapText: Bool?

        public init(numberFormat: String? = nil, bold: Bool? = nil, italic: Bool? = nil, fontColor: Color? = nil,
                    fillColor: Color? = nil, horizontal: Horizontal? = nil, vertical: Vertical? = nil,
                    wrapText: Bool? = nil) {
            self.numberFormat = numberFormat
            self.bold = bold
            self.italic = italic
            self.fontColor = fontColor
            self.fillColor = fillColor
            self.horizontal = horizontal
            self.vertical = vertical
            self.wrapText = wrapText
        }

        public var isEmpty: Bool { self == CellStyleChange() }
    }

    /// 给一块格子改样式，空格子也带上（和 Excel 一样）。调用方先把区域限制在合理的大小（整列有一百多万格）。
    public mutating func restyle(_ range: CellRange, sheet index: Int, _ change: CellStyleChange) {
        guard !change.isEmpty else { return }
        var memo: [Int: Int] = [:]
        for row in range.start.row...range.end.row {
            for column in range.start.column...range.end.column {
                var cell = sheets[index].cells[row, column] ?? Cell()
                let style = memo[cell.styleIndex] ?? restyled(cell.styleIndex, change)
                memo[cell.styleIndex] = style
                cell.styleIndex = style
                sheets[index].cells[row, column] = cell == Cell() ? nil : cell
            }
        }
    }

    /// `base` 这个样式按 `change` 改完以后的编号：已经有一模一样的就用它，没有才往后加。
    mutating func restyled(_ base: Int, _ change: CellStyleChange) -> Int {
        var format = styles.cellFormats.indices.contains(base) ? styles.cellFormats[base] : CellFormat()
        if let code = change.numberFormat { format.numberFormatID = numberFormatID(forCode: code) }
        if change.bold != nil || change.italic != nil || change.fontColor != nil {
            var font = styles.fonts.indices.contains(format.fontID) ? styles.fonts[format.fontID] : FontStyle()
            if let bold = change.bold { font.bold = bold }
            if let italic = change.italic { font.italic = italic }
            switch change.fontColor {
            case .automatic: font.color = nil   // 没写颜色的字跟默认字体走（StyleResolver）
            case .rgb(let color): font.color = StyleColor(.rgb(color))
            case nil: break
            }
            format.fontID = Self.index(of: font, in: &styles.fonts)
        }
        switch change.fillColor {
        case .automatic:
            format.fillID = Self.index(of: FillStyle(pattern: "none"), in: &styles.fills)
        case .rgb(let color):
            let fill = FillStyle(pattern: "solid", foreground: StyleColor(.rgb(color)), background: StyleColor(.indexed(64)))
            format.fillID = Self.index(of: fill, in: &styles.fills)
        case nil:
            break
        }
        // 默认的对齐（常规、靠下）不写：和 Excel 新建的样式一样，xf 里不带 alignment。
        if let horizontal = change.horizontal { format.horizontalAlignment = horizontal == .general ? nil : horizontal.rawValue }
        if let vertical = change.vertical { format.verticalAlignment = vertical == .bottom ? nil : vertical.rawValue }
        if let wrap = change.wrapText { format.wrapText = wrap }
        return Self.index(of: format, in: &styles.cellFormats)
    }

    /// 格式代码 → 编号：几个各地都一样的内置格式用内置编号，别的用自定义编号（已有的复用，没有的从 164 往后加）。
    mutating func numberFormatID(forCode code: String) -> Int {
        if let builtin = BuiltinFormats.id(forCode: code) { return builtin }
        if let existing = styles.customNumberFormats.first(where: { $0.value == code })?.key { return existing }
        // 自定义格式从 164 开始编（0–163 留给内置格式）。
        let id = max(163, styles.customNumberFormats.keys.max() ?? 163) + 1
        styles.customNumberFormats[id] = code
        return id
    }

    private static func index<T: Equatable>(of item: T, in list: inout [T]) -> Int {
        if let existing = list.firstIndex(of: item) { return existing }
        list.append(item)
        return list.count - 1
    }
}
