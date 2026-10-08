import Foundation
import SkySheetCore
import SkySheetFiles
import SkySheetMCPKit

// MARK: - 一次工具调用怎么走（照 SrtFlow 的 AIToolRouter）
//
// 管什么：从通道上收到的调用 → 记客户端名 → 排队 → 交给对应的工具 → 结果。
// switch 对 `MCPToolName` 是穷举的：清单里加了工具、这里没接，编译不过（设计 9.1 节第 1 条）。
// 不管什么：收发（AIBridgeServer）、工具本身（AI*Tools）、这一轮（AISession）。
//
// **排队**：调用按到达的顺序一个接一个做。Claude 会在一条消息里并排发几个调用（比如先 add_sheet 再 write_cells），
// 不排队的话 open_file 这种要等一会儿的调用会被后面的抢先。get_status 只看不改，不排队。

@MainActor
final class AIToolRouter {
    static let shared = AIToolRouter()

    private var tail: Task<Void, Never>?

    private init() {}

    func handle(_ request: MCPBridge.Request) async -> JSONValue {
        guard request.bridge == MCPBridge.version else {
            return MCPBridge.textResult(
                "This SkySheet and its AI helper come from different versions. Ask the user to restart Claude Code.",
                isError: true)
        }
        guard let tool = MCPToolName(rawValue: request.tool) else {
            return MCPBridge.textResult("This SkySheet does not have the tool \(request.tool). Ask the user to update SkySheet.",
                                        isError: true)
        }
        AISession.shared.noteCall(client: request.client)
        let arguments = AIToolArguments(request.arguments)
        guard tool != .getStatus else { return await execute(tool, arguments) }
        let previous = tail
        let work = Task { @MainActor () -> JSONValue in
            await previous?.value
            return await self.execute(tool, arguments)
        }
        tail = Task { _ = await work.value }
        return await work.value
    }

    private func execute(_ tool: MCPToolName, _ arguments: AIToolArguments) async -> JSONValue {
        do {
            return try await run(tool, arguments).json
        } catch let error as AIToolError {
            return MCPBridge.textResult(error.message, isError: true)
        } catch let error as XLSXWriteError {
            return MCPBridge.textResult(error.errorDescription.map { $0 + (error.failureReason.map { " \($0)" } ?? "") }
                                        ?? "\(error)", isError: true)
        } catch {
            return MCPBridge.textResult("SkySheet could not do that: \(error.localizedDescription)", isError: true)
        }
    }

    private func run(_ tool: MCPToolName, _ arguments: AIToolArguments) async throws -> AIToolResult {
        switch tool {
        case .getStatus: return AIWorkbookTools.status()
        case .openFile: return try await AIWorkbookTools.openFile(arguments)
        case .describeSheet: return try AIReadTools.describe(arguments)
        case .readRange: return try AIReadTools.read(arguments)
        case .query: return try AIReadTools.query(arguments)
        case .evaluate: return try AIReadTools.evaluate(arguments)
        case .exportSheet: return try AIReadTools.export(arguments)
        case .show: return try AIWorkbookTools.show(arguments)
        case .saveCopy: return try AIWorkbookTools.saveCopy(arguments)
        case .addSheet: return try AIWriteTools.addSheet(arguments)
        case .writeCells: return try AIWriteTools.writeCells(arguments)
        case .formatCells: return try AIWriteTools.formatCells(arguments)
        case .editSheet: return try AIWriteTools.editSheet(arguments)
        case .undo: return try AIWriteTools.undo(arguments)
        }
    }
}
