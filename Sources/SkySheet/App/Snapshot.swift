import AppKit
import SkySheetCore
import SkySheetFiles

/// 截图模式：`SkySheet --snapshot-input 文件.xlsx --snapshot-output 输出.png [--sheet 名字] [--size 1280x800] [--select K60]
/// [--zoom 1.5]`。
/// `--select` 选中一格或一块（A1 写法），表格会滚过去：用来看滚动以后冻结窗格、行号列标对不对；也可以是整列（C:E）、
/// 整行（3:5），看列标行号选中的样子。
/// 建一个不放上屏幕的窗口（OffscreenWindow），把整个窗口画成 PNG 就退出。开发时用来核对显示（不用录屏权限），
/// 也方便以后给 AI 看表格的样子。2026-11-14 以前是把窗口放在屏幕外很远的地方再 orderFront，现在连放都不放。
///
/// 参数全都带「-」：AppKit 会把命令行里不带「-」的参数当成要打开的文件。打包好的 App 认得文档类型，
/// 打不开 .png 就弹一个模态的错误框，截图模式就卡死在那里（2026-10-08 实测；debug 版不是 .app，没有这个问题）。
struct SnapshotRequest {
    let input: URL
    let output: URL
    let sheetName: String?
    let size: NSSize
    let selection: String?
    /// 缩放比例（2026-11-14 加：改画法时要核对缩放以后画得一不一样）。
    let zoom: Double?

    init?(arguments: [String]) {
        func option(_ name: String) -> String? {
            arguments.firstIndex(of: name).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        guard let input = option("--snapshot-input"), let output = option("--snapshot-output") else { return nil }
        self.input = URL(fileURLWithPath: input)
        self.output = URL(fileURLWithPath: output)
        sheetName = option("--sheet")
        selection = option("--select")
        zoom = option("--zoom").flatMap(Double.init)
        let parts = option("--size")?.split(separator: "x").compactMap { Double($0) } ?? []
        size = parts.count == 2 ? NSSize(width: parts[0], height: parts[1]) : NSSize(width: 1280, height: 800)
    }
}

@MainActor
enum SnapshotRenderer {
    static func run(_ request: SnapshotRequest) {
        do {
            let loaded = try DocumentLoader.load(contentsOf: request.input)
            let session = SheetSession(workbook: loaded.workbook)
            if let name = request.sheetName, let index = loaded.workbook.sheetIndex(named: name) {
                session.showSheet(index)
            }
            if let zoom = request.zoom { session.setZoom(zoom) }
            if let range = request.selection.flatMap({ CellRange.parse($0) }) {
                session.select(range)
            }
            let controller = WorkbookViewController(session: session)
            // 窗口不放上屏幕（OffscreenWindow）：等 SwiftUI 和自动布局排完，直接画进位图。
            let window = OffscreenWindow.make(controller, size: request.size)
            OffscreenWindow.settle(window, for: 0.6)
            guard let bitmap = OffscreenWindow.render(window) else { throw CocoaError(.fileWriteUnknown) }
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            // 只写新文件（NewFile）：输出路径已经有东西就拒绝、以 1 退出，要重截先删掉旧图。
            try NewFile.write(png, to: request.output)
            print("snapshot written to \(request.output.path)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
