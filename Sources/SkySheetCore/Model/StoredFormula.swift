import Foundation

/// 文件里一格的 `<f>` 带着的属性（设计 7.2 节）：没改过的公式写回时照原样带上类型和全部属性。模拟运算表
/// （`t="dataTable"`、`ref`、`r1`）、共享公式（`t="shared"`、`ref`、`si`）这些结构模型里没有，以前改了别的格子一保存
/// 就没了（2026-11-16）。读 xlsx 时记在 sheet 上（`Sheet.storedFormulas`），和富文本的记录一样跟着复制 sheet 走：
/// 副本照原样写，共享公式组、模拟运算表在副本里也不丢（PR #17 第一轮审查第 2 条）。什么属性都没有的 `<f>`
/// 照常写出来本来就一样，不记（大多数公式都是这样，大表不多占内存）。
public struct StoredFormula: Hashable, Sendable {
    /// 共享公式这一格在组里的样子。
    public struct Shared: Hashable, Sendable {
        /// 组号（`si`）。
        public let group: String
        /// 这一组的主格：跟随者从它平移出自己的公式。文件里没有主格时是 nil。
        public let master: CellAddress?
        /// 自己不写原文的跟随者（`<f t="shared" si="0"/>`）。
        public let follower: Bool
        /// 跟随者真正的公式 SkySheet 算不出来（主格里有切不了词又会平移的引用，或者文件里没有主格）：模型里放的是空原文，
        /// 写文件时只能照原样当跟随者写；主格因此不能改（Workbook.lockedFormulaChange）。
        public let unknown: Bool

        public init(group: String, master: CellAddress?, follower: Bool, unknown: Bool) {
            self.group = group
            self.master = master
            self.follower = follower
            self.unknown = unknown
        }
    }

    /// `<f>` 上没有前缀的属性，原样。
    public let attributes: [String: String]
    /// 读进来时模型里这一格的公式原文和数组区域：现在的和它不一样，就是改过了。
    public let source: String
    public let arrayRange: CellRange?
    public let shared: Shared?

    public init(attributes: [String: String], source: String, arrayRange: CellRange?, shared: Shared?) {
        self.attributes = attributes
        self.source = source
        self.arrayRange = arrayRange
        self.shared = shared
    }

    /// 模拟运算表（`t="dataTable"`）占的区域（`ref`），不是模拟运算表是 nil。ref 读不出来时只算它自己这一格。
    public func dataTableRange(at address: CellAddress) -> CellRange? {
        guard attributes["t"] == "dataTable" else { return nil }
        return attributes["ref"].flatMap { CellRange(a1: $0) } ?? CellRange(address)
    }
}
