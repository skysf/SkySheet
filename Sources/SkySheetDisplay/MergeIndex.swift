import Foundation
import SkySheetCore

/// 合并单元格的查找表（2026-11-14，设计 8.2 节「性能」）。
///
/// 画一屏时每个格子都要问「我在不在合并单元格里」，原来每问一次就把整张表的合并单元格从头过一遍：几千个合并单元格的表，
/// 画一屏要几百万次比较，滚一下、按一下方向键都要几百毫秒（2026-11-14 实测 6,500 个合并单元格的表，每帧约 300 毫秒）。
/// 现在按行分桶（每 32 行一桶），一个合并单元格放进它跨过的每一桶，问的时候只看那一桶。
/// 结果和原来一样：按 `merges` 原来的顺序，取第一个包含这一格的（Excel 不许合并单元格重叠，但读进来的文件不一定守规矩）。
public struct MergeIndex: Sendable {
    public let merges: [CellRange]
    /// 桶号 → 跨到这一桶的合并单元格在 `merges` 里的位置，从小到大。
    private let buckets: [Int: [Int]]
    /// 跨的桶太多的（几万行高的大合并）不进桶，每次都看。
    private let tall: [Int]

    static let bucketRows = 32
    static let maxBucketsPerMerge = 1024

    public init(_ merges: [CellRange]) {
        self.merges = merges
        var buckets: [Int: [Int]] = [:]
        var tall: [Int] = []
        for (index, merge) in merges.enumerated() {
            let first = merge.start.row / Self.bucketRows
            let last = merge.end.row / Self.bucketRows
            guard last - first < Self.maxBucketsPerMerge else {
                tall.append(index)
                continue
            }
            for bucket in first...last { buckets[bucket, default: []].append(index) }
        }
        self.buckets = buckets
        self.tall = tall
    }

    public var isEmpty: Bool { merges.isEmpty }

    /// 包含这一格的合并单元格；没有就是 nil。和 `merges.first { $0.contains(address) }` 一样。
    public func merge(containing address: CellAddress) -> CellRange? {
        guard !merges.isEmpty else { return nil }
        var found: Int?
        if let bucket = buckets[address.row / Self.bucketRows] {
            for index in bucket where merges[index].contains(address) {
                found = index
                break
            }
        }
        for index in tall where merges[index].contains(address) {
            if found == nil || index < found! { found = index }
            break
        }
        return found.map { merges[$0] }
    }

    /// 跨到 `rows` 这几行的合并单元格，按 `merges` 原来的顺序。调用方再按需要细筛（比如和要画的区域相交）。
    public func merges(touchingRows rows: ClosedRange<Int>) -> [CellRange] {
        guard !merges.isEmpty else { return [] }
        let first = rows.lowerBound / Self.bucketRows
        let last = rows.upperBound / Self.bucketRows
        var indices: [Int]
        if last - first >= Self.maxBucketsPerMerge {
            indices = Array(merges.indices)
        } else {
            var seen = Set<Int>()
            indices = []
            for bucket in first...last {
                for index in buckets[bucket] ?? [] where seen.insert(index).inserted { indices.append(index) }
            }
            for index in tall where seen.insert(index).inserted { indices.append(index) }
            indices.sort()
        }
        var result: [CellRange] = []
        for index in indices where merges[index].start.row <= rows.upperBound && merges[index].end.row >= rows.lowerBound {
            result.append(merges[index])
        }
        return result
    }
}
