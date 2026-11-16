import Foundation

/// 一个工作簿在 AI 这一轮里的改动次数账（设计 8.3 节「撤销这一轮」）。改动次数是窗口的 `SheetSession.revision`：
/// 每次改、撤销、重做都加一。
///
/// 撤销这一轮 = 换回这一轮开始时存的快照，所以只有这一轮里改这个工作簿的全是 AI 才能这么换：用户中间改过一处，
/// 换回快照就把用户的活一起撤掉了。以前只看「最后一次是不是 AI 改的」：用户改完、AI 再改一次，检查又通过了；
/// 横幅上的按钮连这个都不看（2026-11-16 排查第 2 条）。作者定：不去拆哪些是用户的、只撤 AI 那部分，用户改过就整个拒绝。
public struct AIRoundLedger: Equatable, Sendable {
    /// 下一次 AI 动手之前，改动次数应该停在哪：存快照时的，或者 AI 上一次改完、撤完时的。
    public private(set) var expectedRevision: Int
    /// 这一轮里用户改过这个工作簿。
    public private(set) var userChanged = false

    /// 这一轮第一次改这个工作簿、存快照的时候开账。
    public init(snapshotRevision: Int) {
        expectedRevision = snapshotRevision
    }

    /// AI 改了一步，或者用 undo 撤了一步：`before` 是它动手之前的改动次数，`after` 是之后的。
    /// 动手之前的次数和账上的对不上，说明中间有人（用户）改过。
    public mutating func noteAIStep(before: Int, after: Int) {
        if before != expectedRevision { userChanged = true }
        expectedRevision = after
    }

    /// 改动次数现在是 `revision` 时，能不能整轮撤销：这一轮里改这个工作簿的全是 AI —— 中间没人插进来过，
    /// AI 最后一次动手以后也没人再改。
    public func onlyAIChanged(currentRevision revision: Int) -> Bool {
        !userChanged && revision == expectedRevision
    }
}
