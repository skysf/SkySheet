import Foundation
import SkySheetCore

/// 重写一张原来就有的 sheet 时，哪些公式格子的 `<f>` 照原样写回（设计 7.2 节）。WorksheetWriter 照它写，
/// SaveVerifier 照它核对写出来的 `<f>` 属性对不对（以前模拟运算表的定义丢了，核对只比原文和缓存值，看不出来）。
///
/// 没改过的公式（原文、数组区域都和读进来时一样）带上文件里原来的类型和全部属性（StoredFormula）；别的照常写
/// `<f>原文</f>`（数组公式带 t、ref）。共享公式按组（si）看：
/// - 整组没动：原样（主格带 ref、si 和原文，跟随者只写 `t="shared" si`）。
/// - 动了几格，跟随者的公式算得出来：没动的照常一格一格写原文，和以前一样，组就拆开了。
/// - 动了几格，跟随者的公式算不出来（StoredFormula.Shared.unknown）：主格没动，就保留主格和没动的那几格，动了的写新内容
///   （ECMA-376 第 1 部分 18.3.1.40：区域里自己写了公式、不带 si 的格子用自己的，前后的照旧跟主格）；主格动了，
///   这几格的公式写不出来，拒绝保存，绝不写成引用错的公式（读文件排查第 2 条，2026-11-16）。
enum FormulaElements {
    static func kept(in sheet: Sheet, stored: [CellAddress: StoredFormula]) throws(XLSXWriteError)
        -> [CellAddress: StoredFormula] {
        func unchanged(_ address: CellAddress, _ record: StoredFormula) -> Bool {
            guard let formula = sheet.cells[address]?.formula else { return false }
            return ExactText(formula.source) == ExactText(record.source) && formula.arrayRange == record.arrayRange
        }
        var kept: [CellAddress: StoredFormula] = [:]
        var groups: [String: [(address: CellAddress, record: StoredFormula)]] = [:]
        for (address, record) in stored {
            if let shared = record.shared {
                groups[shared.group, default: []].append((address, record))
            } else if unchanged(address, record) {
                kept[address] = record
            }
        }
        for members in groups.values {
            let same = members.filter { unchanged($0.address, $0.record) }
            if same.count == members.count {
                for member in members { kept[member.address] = member.record }
                continue
            }
            let unknown = same.filter { $0.record.shared?.unknown == true }.min { $0.address < $1.address }
            guard let unknown else { continue }
            let master = unknown.record.shared?.master
            guard let master, same.contains(where: { $0.address == master }) else {
                throw XLSXWriteError.sharedFormulaMasterChanged(sheet: sheet.name, cell: unknown.address.a1,
                                                                master: master?.a1 ?? "?")
            }
            for member in same { kept[member.address] = member.record }
        }
        return kept
    }

    /// 照常写出来的 `<f>` 带的属性（没照原样写回的那些格子）：数组公式是 t 和 ref，别的没有。
    static func plainAttributes(_ formula: CellFormula) -> [String: String] {
        formula.arrayRange.map { ["t": "array", "ref": $0.a1] } ?? [:]
    }

    /// 照原样写回的 `<f>` 上的属性：按 CT_CellFormula 里的先后排（Excel 不在乎先后，排了以后每次写出来都一样）。
    static func attributesXML(_ attributes: [String: String]) -> String {
        let order = ["t", "aca", "ref", "dt2D", "dtr", "del1", "del2", "r1", "r2", "ca", "si", "bx"]
        func rank(_ key: String) -> Int { order.firstIndex(of: key) ?? order.count }
        return attributes.sorted { (rank($0.key), $0.key) < (rank($1.key), $1.key) }
            .map { " \($0.key)=\"\(XMLText.attribute($0.value))\"" }.joined()
    }
}
