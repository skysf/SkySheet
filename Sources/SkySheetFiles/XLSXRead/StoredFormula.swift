import Foundation
import SkySheetCore

/// 文件里一格的 `<f>` 带着的属性（设计 7.2 节）：没改过的公式写回时照原样带上类型和全部属性。模拟运算表
/// （`t="dataTable"`、`ref`、`r1`）、共享公式（`t="shared"`、`ref`、`si`）这些结构模型里没有，以前改了别的格子一保存
/// 就没了，保存校验也看不出来（保存排查第 3 条、读文件排查第 2 条，2026-11-16）。
/// 什么属性都没有的 `<f>` 照常写出来本来就一样，不记（大多数公式都是这样，大表不多占内存）。
struct StoredFormula: Equatable, Sendable {
    /// 共享公式这一格在组里的样子。
    struct Shared: Equatable, Sendable {
        /// 组号（`si`）。
        let group: String
        /// 这一组的主格：跟随者从它平移出自己的公式。文件里没有主格时是 nil。
        let master: CellAddress?
        /// 自己不写原文的跟随者（`<f t="shared" si="0"/>`）。
        let follower: Bool
        /// 跟随者真正的公式 SkySheet 算不出来：主格切不了词、平移又会改它（`A1+SUM(Table1[Amount])`）。
        /// 模型里放的是空原文，写文件时只能照原样当跟随者写，不能当成它的公式写出去。
        let unknown: Bool
    }

    /// `<f>` 上没有前缀的属性，原样。
    let attributes: [String: String]
    /// 读进来时模型里这一格的公式原文和数组区域：现在的和它不一样，就是改过了。
    let source: String
    let arrayRange: CellRange?
    let shared: Shared?
}
