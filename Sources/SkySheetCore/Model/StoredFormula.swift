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
        /// 写文件时只能照原样当跟随者写；这一组主格、跟随者因此都不能改（Workbook.lockedFormulaChange）。
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
    /// 读进来以后这一格的内容被改写过（输入、清空、粘贴、填充、AI 写入……，Workbook.retireReplacedFormulas）：记录作废，
    /// 保存时不再照原样写回，内容后来又变得和读进来时一样也不算。以前只比原文：清空跟随者、再粘上另一组的跟随者，空原文
    /// 对上了旧记录，存出来又跟着原来的主格（PR #17 第二轮审查第 2 条）。作废的记录留着不删，共享公式组少了哪一格才看得出来，
    /// 照「动了几格」写。撤销、重做换回整本快照，记录跟着内容一起回来。
    public var replaced = false

    public init(attributes: [String: String], source: String, arrayRange: CellRange?, shared: Shared?) {
        self.attributes = attributes
        self.source = source
        self.arrayRange = arrayRange
        self.shared = shared
    }

    /// `cell` 还是读进来的那个公式：记录没作废，原文、数组区域都和读进来时一样。保存（FormulaElements）、改之前的拒绝
    /// （Workbook.lockedFormulaChange）都按它看哪些格子没动过。
    public func describes(_ cell: Cell?) -> Bool {
        guard !replaced, let formula = cell?.formula else { return false }
        return ExactText(formula.source) == ExactText(source) && formula.arrayRange == arrayRange
    }

    /// 模拟运算表（`t="dataTable"`）占的区域（`ref`），不是模拟运算表（或者记录作废了）是 nil。ref 读不出来时只算它自己这一格。
    public func dataTableRange(at address: CellAddress) -> CellRange? {
        guard !replaced, attributes["t"] == "dataTable" else { return nil }
        return attributes["ref"].flatMap { CellRange(a1: $0) } ?? CellRange(address)
    }
}
