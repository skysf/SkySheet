import Foundation

/// 把一串 Decimal 按顺序加起来（2026-11-14，设计 8.2 节「性能」）。结果和 `sum += x` 一个一个加完全一样，快几十倍。
///
/// 为什么要它：状态栏的合计要把选中的格子全加起来，Decimal 的加法一次一微秒上下，全选十万行 × 20 列的表要一秒半。
///
/// 怎么保证一样：每个数换成「整数个 10⁻¹⁸」，用 Int128 精确地加。只要每个数最多 18 位小数、每一步的和都在 ±10²⁰ 以内，
/// Decimal 自己的加法也是精确的（对齐小数点后尾数不超过 10³⁸，放得进它 128 位的尾数，不用舍入），两边是同一个数。
/// 有一个数不在这个范围里（公式算出来 38 位有效数字的、特别大的），整串就退回 Decimal 一个一个加（`fallback`），
/// 由调用方再从头加一遍：中途接着加的话，舍入的时机可能和从头加不一样。
public struct DecimalSum: Sendable {
    /// 精确的和，单位 10⁻¹⁸。
    private var units: Int128 = 0
    /// 有数不在快速加法的范围里：结果作废，调用方用 Decimal 从头加。
    public private(set) var needsFallback = false

    static let scale = 18
    /// 尾数的上限：|和| × 10¹⁸ 不能超过它（10³⁸ < 2¹²⁸，Decimal 的尾数放得下）。
    static let limit: Int128 = {
        var value: Int128 = 1
        for _ in 0..<38 { value *= 10 }
        return value
    }()

    public init() {}

    public mutating func add(_ value: Decimal) {
        guard !needsFallback else { return }
        guard let next = Self.units(of: value) else {
            needsFallback = true
            return
        }
        let (sum, overflow) = units.addingReportingOverflow(next)
        guard !overflow, sum > -Self.limit, sum < Self.limit else {
            needsFallback = true
            return
        }
        units = sum
    }

    /// 加起来的和（没退回 Decimal 时才有意义）。
    public var value: Decimal {
        guard units != 0 else { return 0 }
        var magnitude = UInt128(units.magnitude)
        var exponent = -Self.scale
        // 去掉末尾的 0：和 Decimal 一个一个加的结果同一个数（写法可能不同，显示、再算都按数值）。
        while magnitude % 10 == 0 {
            magnitude /= 10
            exponent += 1
        }
        var mantissa: (UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16) = (0, 0, 0, 0, 0, 0, 0, 0)
        var length: UInt32 = 0
        withUnsafeMutableBytes(of: &mantissa) { words in
            var rest = magnitude
            var index = 0
            while rest > 0 {
                words.storeBytes(of: UInt16(truncatingIfNeeded: rest), toByteOffset: index * 2, as: UInt16.self)
                rest >>= 16
                index += 1
            }
            length = UInt32(index)
        }
        return Decimal(_exponent: Int32(exponent), _length: length, _isNegative: units < 0 ? 1 : 0, _isCompact: 1,
                       _reserved: 0, _mantissa: mantissa)
    }

    /// 一个 Decimal 是几个 10⁻¹⁸（精确）；不在范围里就是 nil。
    static func units(of value: Decimal) -> Int128? {
        guard !value.isNaN else { return nil }
        var magnitude: UInt128 = 0
        let length = Int(value._length)
        guard length <= 8 else { return nil }
        withUnsafeBytes(of: value._mantissa) { words in
            for index in stride(from: length - 1, through: 0, by: -1) {
                magnitude = magnitude << 16 | UInt128(words.load(fromByteOffset: index * 2, as: UInt16.self))
            }
        }
        var shift = Int(value._exponent) + scale
        // 小数位比 18 多：末尾是 0 的话可以去掉（不规整的写法），去不掉就不在范围里。
        while shift < 0 {
            guard magnitude % 10 == 0 else { return nil }
            magnitude /= 10
            shift += 1
        }
        for _ in 0..<shift {
            let (product, overflow) = magnitude.multipliedReportingOverflow(by: 10)
            guard !overflow, product < UInt128(limit) else { return nil }
            magnitude = product
        }
        guard magnitude < UInt128(limit) else { return nil }
        let signed = Int128(magnitude)
        return value._isNegative != 0 ? -signed : signed
    }
}
