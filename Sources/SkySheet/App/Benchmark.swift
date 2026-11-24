import AppKit
import SkySheetCore
import SkySheetDisplay
import SkySheetFiles

/// 测速模式的主体：打开、六类动作、量一帧、按屏幕上会发生的事画（用法和量法见 BenchmarkRequest 的说明）。
@MainActor
final class Benchmark {
    let request: BenchmarkRequest
    private var results: [BenchmarkResult] = []
    private(set) var window: NSWindow!
    private(set) var session: SheetSession!
    private(set) var spreadsheet: SpreadsheetView!
    /// 每帧画进这张位图（窗口大小 × 屏幕倍率），只建一次。
    private var canvasContext: CGContext!
    private(set) var scale: CGFloat = 2
    private var lastVisible = CGRect.zero
    /// verify 对不上的步数。
    var verifyMismatches = 0

    init(request: BenchmarkRequest) {
        self.request = request
    }

    func runAll() async throws -> [BenchmarkResult] {
        let url = try prepareFile()
        defer { if request.keepFile == nil, case .synthetic = request.source { try? FileManager.default.removeItem(at: url) } }
        try await open(url)
        printScale()
        if request.only == nil || request.only == "scroll" { await scrolling() }
        if request.only == nil || request.only == "select" || request.only == "arrows" { await selecting() }
        if request.only == nil || request.only == "edit" { await editing() }
        if request.only == nil || request.only == "resize" { await resizing() }
        if request.only == nil || request.only == "switch" { await switching() }
        if request.only == "verify" { verifyMismatches = await verifyPartialRedraws() }
        printResults()
        return results
    }

    // MARK: - 准备和打开

    /// 合成的表写成 xlsx（不算进「打开」）。只写新文件（NewFile）：`--benchmark-file` 指到已有的文件上就拒绝，
    /// 绝不把别的工作簿换成合成表。
    private func prepareFile() throws -> URL {
        switch request.source {
        case .file(let url):
            return url
        case .synthetic(let kind):
            let started = ContinuousClock.now
            let workbook = kind.make(scale: request.scale)
            let data = try XLSXWriter.write(workbook, source: nil, baseline: nil).data
            let url = request.keepFile ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("SkySheetBenchmark-\(UUID().uuidString).xlsx")
            try NewFile.write(data, to: url)
            print(String(format: "generated synthetic:%@ (%.1f MB) in %.1f s", kind.rawValue,
                         Double(data.count) / 1_048_576, seconds(since: started)))
            return url
        }
    }

    /// 打开：读 xlsx、整本重算、建窗口、画出第一屏，分开量。也记主线程 CPU 时间：机器忙的时候（测速是 nice 着跑的）
    /// 墙上时间里有一大段是在等 CPU，CPU 时间才是这几步自己的活；墙上时间另外打印出来。
    private func open(_ url: URL) async throws {
        var wall = ContinuousClock.now
        var cpu = threadCPU()
        var workbook: Workbook
        var walls: [String] = []
        let cache = RecalcCache()
        func lap(_ name: String) {
            record(name, [FrameSample(ms: threadCPU() - cpu, builds: DrawStats.canvasBuilds, panes: DrawStats.paneDraws,
                                      headers: DrawStats.headerDraws, area: DrawStats.paneArea)])
            walls.append(String(format: "%@ %.0f ms", name, milliseconds(since: wall)))
            wall = ContinuousClock.now
            cpu = threadCPU()
        }
        if LoadedWorkbook.isDelimitedText(url: url, typeName: nil) {
            let loaded = try DocumentLoader.load(contentsOf: url)
            workbook = loaded.workbook
            lap("open: read + recalc (csv)")
        } else {
            workbook = try XLSXReader.readDocument(Data(contentsOf: url)).workbook
            lap("open: read xlsx")
            Recalculator.recalculate(&workbook, options: RecalcOptions(cache: cache))
            lap("open: recalculate")
        }

        DrawStats.reset()
        DrawStats.tracksDirtyRects = true
        session = SheetSession(workbook: workbook, recalcCache: cache)
        if let index = request.sheetIndex ?? request.sheetName.flatMap(workbook.sheetIndex(named:)) { session.showSheet(index) }
        let controller = WorkbookViewController(session: session)
        window = OffscreenWindow.make(controller, size: request.size)
        spreadsheet = controller.spreadsheet
        scale = window.backingScaleFactor
        let pixels = (width: Int(request.size.width * scale), height: Int(request.size.height * scale))
        canvasContext = CGContext(data: nil, width: pixels.width, height: pixels.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        await settle()
        // 第一屏：每个格子视图看得见的部分整个画一遍。
        DrawStats.dirty = [:]
        for view in gridViews(in: spreadsheet) { draw(view, view.visibleRect) }
        lap("open: window + first screen")
        print("wall clock: " + walls.joined(separator: ", "))
        // 主区滚动时新露出来的部分要画（系统在屏幕上也只画这一部分）。
        let clip = spreadsheet.scrollView.contentView
        lastVisible = clip.bounds
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { _ in
            MainActor.assumeIsolated { self.exposeScrolledArea() }
        }
        try? await Task.sleep(for: .milliseconds(300))
    }

    private func printScale() {
        let workbook = session.workbook
        print("workbook: \(workbook.sheets.count) sheets, \(workbook.styles.cellFormats.count) cell styles,"
              + " window \(Int(request.size.width))×\(Int(request.size.height)) @\(scale)x")
        for sheet in workbook.sheets {
            var formulas = 0
            sheet.cells.forEach { _, cell in if cell.formula != nil { formulas += 1 } }
            let used = sheet.cells.usedRange
            let size = used.map { "\($0.end.row + 1) rows × \($0.end.column + 1) columns" } ?? "empty"
            print("  sheet: \(size), \(sheet.cells.count) cells, \(formulas) formulas, \(sheet.merges.count) merges,"
                  + " frozen \(sheet.frozen.map { "\($0.rows)×\($0.columns)" } ?? "none")"
                  + (sheet.id == session.sheet.id ? "  ← measured" : ""))
        }
    }

    // MARK: - 六类动作

    private func scrolling() async {
        let clip = spreadsheet.scrollView.contentView
        let rowStep = 3 * (spreadsheet.canvas?.geometry.rows.defaultSize ?? 20)
        let columnStep = spreadsheet.canvas?.geometry.columns.defaultSize ?? 64
        func scroll(to point: CGPoint) {
            let document = spreadsheet.mainPane.frame.size
            let limit = CGPoint(x: Swift.max(0, document.width - clip.bounds.width),
                                y: Swift.max(0, document.height - clip.bounds.height))
            clip.scroll(to: CGPoint(x: Swift.min(Swift.max(point.x, 0), limit.x), y: Swift.min(Swift.max(point.y, 0), limit.y)))
            spreadsheet.scrollView.reflectScrolledClipView(clip)
        }
        let cycling = request.cycleScroll && request.only == "scroll" && request.frames > 20
        let downReset: ((Int) -> Void)? = cycling ? { index in
            if index % 20 == 0 { scroll(to: .zero) }
        } : nil
        await idle { scroll(to: .zero) }
        await measure("scroll down (3 rows / frame)", prepare: downReset) { index in
            scroll(to: CGPoint(x: 0, y: CGFloat((cycling ? index % 20 : index) + 1) * rowStep))
        }
        let bottom = clip.bounds.origin.y
        let upReset: ((Int) -> Void)? = cycling ? { index in
            if index % 20 == 0 { scroll(to: CGPoint(x: 0, y: bottom)) }
        } : nil
        await measure("scroll up", prepare: upReset) { index in
            scroll(to: CGPoint(x: 0, y: bottom - CGFloat((cycling ? index % 20 : index) + 1) * rowStep))
        }
        await idle { scroll(to: CGPoint(x: 0, y: 30 * rowStep)) }
        let y = clip.bounds.origin.y
        // 横着来回滚：表可能没那么宽，到头了就往回。
        let span = Swift.max(0, spreadsheet.mainPane.frame.width - clip.bounds.width)
        await measure("scroll left / right (1 column / frame)") { index in
            let steps = Swift.max(1, Int(span / columnStep))
            let position = index % (2 * steps)
            let column = position < steps ? position + 1 : 2 * steps - position - 1
            scroll(to: CGPoint(x: CGFloat(column) * columnStep, y: y))
        }
        await idle { scroll(to: .zero) }
    }

    private func selecting() async {
        let start = firstBodyCell
        let cycling = request.only == "arrows" && request.frames > 20
        let reset: ((Int) -> Void)? = cycling ? { index in
            if index % 40 == 0 { self.session.select(start) }
        } : nil
        await idle { session.select(start) }
        await measure(cycling ? "arrow up / down" : "arrow down (move selection)", prepare: reset) { index in
            session.moveCursor(rows: cycling && index % 40 >= 20 ? -1 : 1, columns: 0)
        }
        await idle { session.select(start) }
        await measure(cycling ? "arrow left / right" : "arrow right", prepare: reset) { index in
            session.moveCursor(rows: 0, columns: cycling && index % 40 >= 20 ? -1 : 1)
        }
        if request.only == "arrows" { return }
        await idle { session.select(start) }
        await measure("shift + arrow down (extend)") { _ in session.moveCursor(rows: 1, columns: 0, extend: true) }
        await idle { session.select(start) }
        await measure("drag select") { index in
            session.select(CellAddress(row: start.row + index, column: start.column + index / 4), extend: true)
        }
        var all: [FrameSample] = []
        var single: [FrameSample] = []
        for _ in 0..<limited(8) {
            all.append(await frame { session.selectAll() })
            single.append(await frame { session.select(start) })
        }
        record("select all", all)
        record("click one cell after select all", single)
    }

    private func editing() async {
        guard let target = editTarget else { return print("  (no number cell to edit)") }
        await idle { session.select(target) }
        let original = session.rawText(at: target)
        // 打字那几帧不算：从按回车（提交）量起，到重算、重画完。
        await measure("edit a cell + commit", frames: limited(12), prepare: { [session] index in
            session?.beginEditing(.typing, text: String(100 + index))
        }) { _ in
            session.commitEditing()
        }
        await idle {
            session.beginEditing(.typing, text: original)
            session.commitEditing()
        }
    }

    private func resizing() async {
        let column = firstBodyCell.column + 1
        await measure("drag column width (preview)") { index in
            session.resizePreview = ResizePreview(axis: .columns, lines: column...column, size: 10 + Double(index % 20) * 0.5)
        }
        await measure("drag column width: release", frames: 1) { _ in spreadsheet.finishResize() }
        let row = firstBodyCell.row + 1
        await measure("drag row height (preview)") { index in
            session.resizePreview = ResizePreview(axis: .rows, lines: row...row, size: 15 + Double(index % 20) * 0.75)
        }
        await measure("drag row height: release", frames: 1) { _ in spreadsheet.finishResize() }
    }

    private func switching() async {
        let measured = session.sheetIndex
        if let other = session.tabIndices.first(where: { $0 != measured }) {
            var away: [FrameSample] = []
            var back: [FrameSample] = []
            for _ in 0..<limited(10) {
                away.append(await frame { session.showSheet(other) })
                back.append(await frame { session.showSheet(measured) })
            }
            record("switch to another sheet", away)
            record("switch back to this sheet", back)
        }
        let zooms = [1.1, 1.25, 1.5, 1.25, 1.0, 0.9, 0.75, 0.9]
        await measure("zoom") { index in session.setZoom(zooms[index % zooms.count]) }
        await idle { session.setZoom(1) }
    }

    // MARK: - 量

    /// 慢的几类（全选、改格子、换 sheet）平时少做几帧；只量这一类（--benchmark-only，给 sample 采样）时照 --frames 做。
    private func limited(_ frames: Int) -> Int {
        request.only == nil ? Swift.min(request.frames, frames) : request.frames
    }

    /// 选区、编辑从这里开始：冻结区右下的第一格。
    var firstBodyCell: CellAddress {
        CellAddress(row: session.sheet.frozen?.rows ?? 0, column: session.sheet.frozen?.columns ?? 0)
    }

    /// 改哪一格：别的公式最多引用的那种最好（合成的还款表是 H1 利率，一改全表重算）；别的表取第一个数字格子。
    private var editTarget: CellAddress? {
        let sheet = session.sheet
        if case .synthetic(.formulas) = request.source { return CellAddress(row: 0, column: 7) }
        for row in sheet.cells.rowIndices {
            if let (column, _) = sheet.cells.row(row).first(where: { $0.value.formula == nil && $0.value.value.number != nil }) {
                return CellAddress(row: row, column: column)
            }
        }
        return nil
    }

    /// `prepare` 在每一帧之前做、不计时（比如先进入编辑，只量提交那一下）。
    private func measure(_ name: String, frames: Int? = nil, prepare: ((Int) -> Void)? = nil,
                         _ action: (Int) -> Void) async {
        // 长导航测量先预热，再反复走同一段；否则短样本被冷缓存和机器频率波动左右，长样本又会到边后空转。
        if request.frames > 20, request.only == "arrows" || (request.only == "scroll" && request.cycleScroll) {
            for index in 0..<20 {
                if let prepare { await idle { prepare(index) } }
                await idle { action(index) }
            }
        }
        var samples: [FrameSample] = []
        for index in 0..<(frames ?? request.frames) {
            if let prepare { await idle { prepare(index) } }
            samples.append(await frame { action(index) })
        }
        record(name, samples)
    }

    private func record(_ name: String, _ samples: [FrameSample]) {
        results.append(BenchmarkResult(name: name, frames: samples))
    }

    /// 不计时地做一件事，并把它引起的重画做完。
    private func idle(_ action: () -> Void) async {
        _ = await frame(action)
    }

    /// 一帧：见 BenchmarkRequest 的说明。
    private func frame(_ action: () -> Void) async -> FrameSample {
        DrawStats.reset()
        let started = threadCPU()
        action()
        await settle()
        for (view, rect) in DrawStats.dirty.values { draw(view, rect.intersection(view.visibleRect)) }
        DrawStats.dirty = [:]
        return FrameSample(ms: threadCPU() - started, builds: DrawStats.canvasBuilds, panes: DrawStats.paneDraws,
                           headers: DrawStats.headerDraws, area: DrawStats.paneArea)
    }

    /// 主线程到现在用掉的 CPU 时间（毫秒）。
    private func threadCPU() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e6
    }

    /// observeChanges 的回调是排在主线程上的 Task：先让一下，它们就排在前面跑完（主线程上的 Task 先来先跑）。
    /// 再睡一小会儿，run loop 走到「快睡了」那一步，SwiftUI 的更新在那时做；最后把自动布局排完。
    func settle() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(4))
        window.layoutIfNeeded()
    }

    /// 主区滚了：新露出来的部分要画。
    private func exposeScrolledArea() {
        let clip = spreadsheet.scrollView.contentView
        let visible = clip.bounds
        defer { lastVisible = visible }
        guard visible.intersects(lastVisible) else { return DrawStats.invalidated(spreadsheet.mainPane, visible) }
        let overlap = visible.intersection(lastVisible)
        if visible.minY < overlap.minY {
            DrawStats.invalidated(spreadsheet.mainPane, CGRect(x: visible.minX, y: visible.minY, width: visible.width,
                                                               height: overlap.minY - visible.minY))
        }
        if visible.maxY > overlap.maxY {
            DrawStats.invalidated(spreadsheet.mainPane, CGRect(x: visible.minX, y: overlap.maxY, width: visible.width,
                                                               height: visible.maxY - overlap.maxY))
        }
        if visible.minX < overlap.minX {
            DrawStats.invalidated(spreadsheet.mainPane, CGRect(x: visible.minX, y: overlap.minY,
                                                               width: overlap.minX - visible.minX, height: overlap.height))
        }
        if visible.maxX > overlap.maxX {
            DrawStats.invalidated(spreadsheet.mainPane, CGRect(x: overlap.maxX, y: overlap.minY,
                                                               width: visible.maxX - overlap.maxX, height: overlap.height))
        }
    }

    /// 像系统那样画一个视图的一块：坐标换到视图自己的（翻转的视图上下翻过来），裁到这一块，调它的 draw。
    private func draw(_ view: NSView, _ rect: CGRect) {
        guard !rect.isEmpty, let canvasContext else { return }
        let context = NSGraphicsContext(cgContext: canvasContext, flipped: view.isFlipped)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        canvasContext.saveGState()
        canvasContext.scaleBy(x: scale, y: scale)
        if view.isFlipped {
            canvasContext.translateBy(x: 0, y: rect.height)
            canvasContext.scaleBy(x: 1, y: -1)
        }
        canvasContext.translateBy(x: -rect.minX, y: -rect.minY)
        canvasContext.clip(to: rect)
        view.draw(rect)
        canvasContext.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 表格自己画的那几个视图：四块窗格、行号列标、左上角。
    func gridViews(in view: NSView) -> [NSView] {
        view.subviews.flatMap { subview -> [NSView] in
            (subview is PaneView || subview is HeaderView || subview is CornerBox ? [subview] : []) + gridViews(in: subview)
        }
    }

    private func printResults() {
        print("")
        print(pad("action", 40) + pad("frames", 8, right: true) + pad("median", 10, right: true) + pad("p95", 10, right: true)
              + pad("max", 10, right: true) + "   per frame: builds / panes / headers / area")
        for result in results {
            let numbers = [result.median, result.p95, result.max].map { pad(String(format: "%.2f", $0), 10, right: true) }
            print(pad(result.name, 40) + pad("\(result.frames.count)", 8, right: true) + numbers.joined()
                  + String(format: "   %.1f / %.1f / %.1f / %.0fk", result.average { Double($0.builds) },
                           result.average { Double($0.panes) }, result.average { Double($0.headers) },
                           result.average(\.area) / 1000))
        }
        print("(milliseconds of main-thread CPU time; wall clock of the open steps is printed above)")
    }

    private func pad(_ text: String, _ width: Int, right: Bool = false) -> String {
        let padding = String(repeating: " ", count: Swift.max(0, width - text.count))
        return right ? padding + text : text + padding
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        seconds(since: start) * 1000
    }

    private func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}
