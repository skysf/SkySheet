import Foundation

// MARK: - AI 的每个改动是一步撤销（照搬 SrtFlow 的 AIUndoGrouping，那边踩过的坑）
//
// 撤销管理器登记时按「事件」自动开一组，要等下一个用户事件才关上。AI 的调用不是事件，App 又常在后台一个事件都收不到：
// 不显式分组的话 AI 的每一步都堆进同一组，⌘Z 一按全部退光。也不能去手动关那个自动组（下一次登记会抛异常、App 闪退）。
// 所以这里绕开按事件分组：暂时关掉它、自己开一组、做完关上、再恢复。必须是同步的一段（不许有 await）。
// 进来时已经开着一组（用户刚做完、还没等到下一个事件的那一组）就不另开，嵌在里面：两步并成一步，但不会崩。

@MainActor
enum AIUndoGrouping {
    static func step<T>(_ manager: UndoManager?, _ body: () throws -> T) rethrows -> T {
        guard let manager, manager.groupingLevel == 0 else { return try body() }
        let byEvent = manager.groupsByEvent
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        defer {
            // 中间有人清空了撤销栈（removeAllActions 会把开着的组一起丢掉），就没有组可关了。
            if manager.groupingLevel > 0 { manager.endUndoGrouping() }
            manager.groupsByEvent = byEvent
        }
        return try body()
    }
}
