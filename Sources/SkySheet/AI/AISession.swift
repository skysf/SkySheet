import Foundation
import Observation
import SkySheetCore

// MARK: - AI 这一轮：谁在改、改了几处、能不能整轮撤销（设计 8.3 节，照 SrtFlow 的 AISession）
//
// 管什么：横幅上显示的状态、「撤销这一轮」要用的快照（每个被改到的工作簿一份）、这一轮改过的格子（高亮）、
// AI 最后一次改完时文档的改动次数（之后用户又改过，AI 就不许撤销，免得撤掉用户的活）。
// 不管什么：工具怎么做（AI*Tools）、调用怎么排队（AIToolRouter）。
//
// **「一轮」按时间划分**：服务器看不到对话，只能这么判断 —— AI 开始改的时候开一轮，连续 30 秒没有新调用就算结束
// （横幅换成「改了 N 处 · 撤销这一轮」）。

@MainActor
@Observable
final class AISession {
    static let shared = AISession()

    enum Phase: Equatable {
        case idle
        case working
        case finished
    }

    static let roundIdleSeconds = 30.0

    private(set) var phase: Phase = .idle
    /// 横幅、署名上的客户端名（人认得的写法，如 "Claude Code"）。
    private(set) var clientName = "AI"
    /// AI 在 add_sheet 里自报的模型名；同一个客户端后面的调用沿用（设计 9.3 节第 5 条）。
    var model: String?
    /// 这一轮改了几处（每个改了工作簿的调用算一处）。
    private(set) var changeCount = 0
    /// 这一轮改到的窗口（SheetSession）。横幅只在这些窗口里出现。
    private(set) var touched: Set<ObjectIdentifier> = []

    @ObservationIgnored private var snapshots: [ObjectIdentifier: Workbook] = [:]
    @ObservationIgnored private var sessions: [ObjectIdentifier: WeakSession] = [:]
    @ObservationIgnored private var lastAIRevision: [ObjectIdentifier: Int] = [:]
    /// 撤销栈顶上连着几步是 AI 的（用户一改就从头数）：AI 的 undo 最多撤这么多步，撤不到用户的活。
    @ObservationIgnored private var aiSteps: [ObjectIdentifier: Int] = [:]
    @ObservationIgnored private var idleTask: Task<Void, Never>?

    private init() {}

    /// 署名用的「谁」。
    var author: AIAuthorship.Mark.Author { .ai(client: clientName, model: model) }

    // MARK: 调用进来

    func noteCall(client: String?) {
        if let client, !client.isEmpty { clientName = AIAuthorship.brand(ofClient: client) }
        if phase == .working { scheduleRoundEnd() }
    }

    /// 要改一个工作簿之前调：没在一轮里就开一轮（上一轮的高亮清掉）；这一轮第一次改这个工作簿就先存一份快照。
    func beginChange(in session: SheetSession) {
        if phase != .working {
            for case let weak in sessions.values { weak.session?.aiTouched = [:] }
            snapshots = [:]
            sessions = [:]
            touched = []
            changeCount = 0
            phase = .working
        }
        let key = ObjectIdentifier(session)
        if snapshots[key] == nil {
            snapshots[key] = session.workbook
            sessions[key] = WeakSession(session: session)
        }
        scheduleRoundEnd()
    }

    /// 改完了：记一处，高亮改到的格子（sheet 编号 → 格子），记下这时的改动次数。`revisionBefore` 是改之前的改动次数：
    /// 和 AI 上一次改完时一样，说明中间用户没动过，这一步和前面几步连着。
    func noteChange(in session: SheetSession, revisionBefore: Int, cells: [Int: Set<CellAddress>] = [:]) {
        let key = ObjectIdentifier(session)
        changeCount += 1
        touched.insert(key)
        aiSteps[key] = (lastAIRevision[key] == revisionBefore ? aiSteps[key] ?? 0 : 0) + 1
        lastAIRevision[key] = session.revision
        for (sheet, addresses) in cells {
            session.aiTouched[sheet, default: []].formUnion(addresses)
        }
    }

    /// AI 上一次改完以后用户没再动过：AI 的 undo 才可以撤（撤掉的就是 AI 自己那一步）。
    func lastChangeIsAI(in session: SheetSession) -> Bool {
        lastAIRevision[ObjectIdentifier(session)] == session.revision
    }

    func hasUndoableStep(in session: SheetSession) -> Bool {
        lastChangeIsAI(in: session) && (aiSteps[ObjectIdentifier(session)] ?? 0) > 0
    }

    /// AI 撤了一步（或者整轮）：栈顶少了一步 AI 的。整轮撤完，栈顶是「撤销这一轮」那一步，不再往下撤。
    func noteUndo(in session: SheetSession, round: Bool = false) {
        let key = ObjectIdentifier(session)
        aiSteps[key] = round ? 0 : max((aiSteps[key] ?? 0) - 1, 0)
        lastAIRevision[key] = session.revision
    }

    func canUndoRound(in session: SheetSession) -> Bool {
        snapshots[ObjectIdentifier(session)] != nil && touched.contains(ObjectIdentifier(session))
    }

    /// 把这个工作簿换回这一轮开始之前（一步，可以再 ⌘Z 回来）。
    @discardableResult
    func undoRound(in session: SheetSession) -> Bool {
        let key = ObjectIdentifier(session)
        guard let snapshot = snapshots[key], touched.contains(key) else { return false }
        session.apply(String(localized: "Undo AI Changes")) { $0 = snapshot }
        session.aiTouched = [:]
        touched.remove(key)
        snapshots[key] = nil
        if touched.isEmpty { phase = .idle }
        return true
    }

    /// 关掉横幅：这一轮的高亮也一起清掉。
    func dismiss(_ session: SheetSession) {
        session.aiTouched = [:]
        touched.remove(ObjectIdentifier(session))
        if touched.isEmpty, phase == .finished { phase = .idle }
    }

    private func scheduleRoundEnd() {
        idleTask?.cancel()
        idleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.roundIdleSeconds * 1_000_000_000))
            guard let self, !Task.isCancelled, self.phase == .working else { return }
            self.phase = self.changeCount > 0 ? .finished : .idle
        }
    }

    private struct WeakSession {
        weak var session: SheetSession?
    }
}
