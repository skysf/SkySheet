import Foundation

/// 一个格子的位置。行、列都从 0 开始（A1 = 第 0 行第 0 列）；界面和公式里的写法用 `a1` 换算。
public struct CellAddress: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var row: Int
    public var column: Int

    /// Excel 的上限：1,048,576 行、16,384 列（XFD）。
    public static let maxRows = 1_048_576
    public static let maxColumns = 16_384

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    /// 解析 "B12"、"$B$12"（$ 只是绝对引用的标记，这里忽略）。超出 Excel 的范围返回 nil。
    /// 读 xlsx 时每个格子都要解析一次地址（`<c r="B12">`）：先按字节走一遍（2026-11-14，原来这一步占读文件的两成），
    /// 规则和下面原来的写法一模一样：去掉所有 $，开头 1–3 个英文字母，后面全是 0–9，列不超过 XFD，行在 1…1,048,576。
    public init?(a1 text: some StringProtocol) {
        var letters = 0
        var column = 0
        var digits = 0
        var row = 0
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "$"):
                continue
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"):
                guard digits == 0, letters < 3 else { return nil }
                letters += 1
                column = column * 26 + Int(byte | 0x20) - 96
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                digits += 1
                row = min(row * 10 + Int(byte - UInt8(ascii: "0")), CellAddress.maxRows + 1)
            default:
                return nil
            }
        }
        guard letters > 0, digits > 0, column <= CellAddress.maxColumns, row >= 1, row <= CellAddress.maxRows else {
            return nil
        }
        self.init(row: row - 1, column: column - 1)
    }

    /// 原来的写法（按 Unicode 标量）。留着给自检和上面的快速写法对照。
    init?(slowA1 text: some StringProtocol) {
        let scalars = Array(text.unicodeScalars.filter { $0 != "$" })
        let letterCount = scalars.prefix { CellAddress.isASCIILetter($0) }.count
        let digits = scalars.dropFirst(letterCount)
        guard letterCount > 0, !digits.isEmpty, digits.allSatisfy({ $0.properties.numericType == .decimal && $0.isASCII }),
              let column = CellAddress.columnIndex(String(String.UnicodeScalarView(scalars.prefix(letterCount)))),
              let rowNumber = Int(String(String.UnicodeScalarView(digits))),
              rowNumber >= 1, rowNumber <= CellAddress.maxRows
        else { return nil }
        self.init(row: rowNumber - 1, column: column)
    }

    public var a1: String { CellAddress.columnName(column) + String(row + 1) }
    public var description: String { a1 }

    /// 行优先：先比行，再比列。和 xlsx 里格子的排列顺序一致。
    public static func < (lhs: CellAddress, rhs: CellAddress) -> Bool {
        (lhs.row, lhs.column) < (rhs.row, rhs.column)
    }

    /// 0 → "A"，25 → "Z"，26 → "AA"。
    public static func columnName(_ index: Int) -> String {
        var number = index + 1
        var scalars: [Unicode.Scalar] = []
        while number > 0 {
            let remainder = (number - 1) % 26
            scalars.append(Unicode.Scalar(UInt8(65 + remainder)))
            number = (number - 1) / 26
        }
        return String(String.UnicodeScalarView(scalars.reversed()))
    }

    /// "A" → 0，"xfd" → 16383（不分大小写）。不是 1–3 个英文字母、或者超过 XFD，返回 nil。
    public static func columnIndex(_ letters: some StringProtocol) -> Int? {
        guard (1...3).contains(letters.unicodeScalars.count) else { return nil }
        var value = 0
        for scalar in letters.unicodeScalars {
            guard isASCIILetter(scalar) else { return nil }
            value = value * 26 + Int(scalar.value | 0x20) - 96
        }
        return value <= maxColumns ? value - 1 : nil
    }

    static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }
}
