import AppKit
import SkySheetCore
import SkySheetDisplay
import SkySheetFiles

/// 测速模式（2026-11-14，设计 8.2 节「性能」）：
/// `SkySheet --benchmark synthetic:data|synthetic:formulas|synthetic:styles|文件.xlsx [--sheet 名字] [--size 1280x800]
///  [--frames 40] [--benchmark-only scroll|select|edit|resize|switch] [--benchmark-file 存合成表的路径.xlsx]
///  [--benchmark-json 结果.json]`
///
/// 把作者说卡的六类动作（打开、滚动、移动选区、改格子、拖列宽行高、换 sheet 和缩放）各做若干帧，打印每类的中位数、
/// p95、最大值。合成的表先写成 xlsx 再打开：「打开」走的和双击文件是同一条路。
/// 量出来的数字要用 release 构建（`swift build -c release --arch arm64 --product SkySheet`），debug 的会误导。
///
/// 全程在后台：窗口不放上屏幕（OffscreenWindow），系统不会来画它，所以每一帧由这里照着屏幕上会发生的事来画——
/// 表格视图标脏的区域（DrawStats 记下来的），加上主区滚动时新露出来的那一条（系统滚动时只画新露出的部分，
/// 2026-11-14 用放在屏幕外的真窗口对过：每帧画的面积就是新露出的条加上跟着动的冻结窗格）——画进一张位图。
///
/// 一帧的耗时 = 做这个动作、跑完 observeChanges 的回调和 SwiftUI 的更新、排版、画完期间**主线程用掉的 CPU 时间**。
/// 不用墙上时间：中间等 run loop 的那几毫秒不算，量的就是这一帧把主线程占了多久。参数都带「-」，原因见 SnapshotRequest。
struct BenchmarkRequest {
    enum Source {
        case synthetic(SyntheticWorkbook)
        case file(URL)
    }

    let source: Source
    let sheetName: String?
    let size: NSSize
    let frames: Int
    /// 合成的表存在哪（留着给截图模式比对用）；不给就写进临时目录，跑完删掉。
    let keepFile: URL?
    let json: URL?
    /// 只量某一类（scroll、select、edit、resize、switch），配合很多帧给 `sample` 采样用。
    let only: String?

    init?(arguments: [String]) {
        func option(_ name: String) -> String? {
            arguments.firstIndex(of: name).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        guard let input = option("--benchmark") else { return nil }
        if input.hasPrefix("synthetic:") {
            guard let kind = SyntheticWorkbook(rawValue: String(input.dropFirst("synthetic:".count))) else { return nil }
            source = .synthetic(kind)
        } else {
            source = .file(URL(fileURLWithPath: input))
        }
        sheetName = option("--sheet")
        let parts = option("--size")?.split(separator: "x").compactMap { Double($0) } ?? []
        size = parts.count == 2 ? NSSize(width: parts[0], height: parts[1]) : NSSize(width: 1280, height: 800)
        frames = option("--frames").flatMap(Int.init) ?? 40
        keepFile = option("--benchmark-file").map { URL(fileURLWithPath: $0) }
        json = option("--benchmark-json").map { URL(fileURLWithPath: $0) }
        only = option("--benchmark-only")
    }
}

/// 表格视图每帧做了多少事（重建了几次画布、画了几块、画了多大），以及测速模式下哪些视图标了脏、脏在哪。
/// 平时只是几个加法和一次判断。
@MainActor
enum DrawStats {
    static var canvasBuilds = 0
    static var paneDraws = 0
    static var headerDraws = 0
    /// 窗格画过的面积（平方点）。
    static var paneArea: Double = 0
    /// 测速模式打开：记下每个格子视图要重画的区域（窗口不在屏幕上，系统不会来画，测速照着画）。
    static var tracksDirtyRects = false
    static var dirty: [ObjectIdentifier: (view: NSView, rect: CGRect)] = [:]

    static func reset() {
        canvasBuilds = 0
        paneDraws = 0
        headerDraws = 0
        paneArea = 0
    }

    /// 视图标脏（setNeedsDisplay）时调。同一个视图标了几处就合成一块：系统也是把这一块交给 draw 的。
    static func invalidated(_ view: NSView, _ rect: CGRect) {
        guard tracksDirtyRects, !rect.isEmpty else { return }
        let key = ObjectIdentifier(view)
        dirty[key] = (view, dirty[key].map { $0.rect.union(rect) } ?? rect)
    }
}

@MainActor
enum BenchmarkRunner {
    static func start(_ request: BenchmarkRequest) {
        Task { @MainActor in
            do {
                let results = try await Benchmark(request: request).runAll()
                if let url = request.json {
                    let rows = results.map { ["name": $0.name, "median": $0.median, "p95": $0.p95, "max": $0.max,
                                              "frames": $0.frames.count] as [String: Any] }
                    let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
                    try data.write(to: url)
                }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("benchmark failed: \(error)\n".utf8))
                exit(1)
            }
        }
    }
}

/// 一帧量到的：主线程 CPU 毫秒，和这一帧里表格视图做了多少事（DrawStats）。
struct FrameSample {
    var ms: Double
    var builds = 0
    var panes = 0
    var headers = 0
    var area = 0.0
}

/// 一类动作量出来的结果。
struct BenchmarkResult {
    let name: String
    let frames: [FrameSample]

    private var sorted: [Double] { frames.map(\.ms).sorted() }
    var median: Double { sorted.isEmpty ? 0 : sorted[sorted.count / 2] }
    var p95: Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)] }
    var max: Double { sorted.last ?? 0 }

    /// 平均每帧的 DrawStats。
    func average(_ value: (FrameSample) -> Double) -> Double {
        frames.isEmpty ? 0 : frames.map(value).reduce(0, +) / Double(frames.count)
    }
}

@MainActor
private final class Benchmark {
    let request: BenchmarkRequest
    private var results: [BenchmarkResult] = []
    private var window: NSWindow!
    private var session: SheetSession!
    private var spreadsheet: SpreadsheetView!
    /// 每帧画进这张位图（窗口大小 × 屏幕倍率），只建一次。
    private var canvasContext: CGContext!
    private var scale: CGFloat = 2
    private var lastVisible = CGRect.zero

    init(request: BenchmarkRequest) {
        self.request = request
    }

    func runAll() async throws -> [BenchmarkResult] {
        let url = try prepareFile()
        defer { if request.keepFile == nil, case .synthetic = request.source { try? FileManager.default.removeItem(at: url) } }
        try await open(url)
        printScale()
        if request.only == nil || request.only == "scroll" { await scrolling() }
        if request.only == nil || request.only == "select" { await selecting() }
        if request.only == nil || request.only == "edit" { await editing() }
        if request.only == nil || request.only == "resize" { await resizing() }
        if request.only == nil || request.only == "switch" { await switching() }
        printResults()
        return results
    }

    // MARK: - 准备和打开

    /// 合成的表写成 xlsx（不算进「打开」）。
    private func prepareFile() throws -> URL {
        switch request.source {
        case .file(let url):
            return url
        case .synthetic(let kind):
            let started = ContinuousClock.now
            let workbook = kind.make()
            let data = try XLSXWriter.write(workbook, source: nil, baseline: nil).data
            let url = request.keepFile ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("SkySheetBenchmark-\(UUID().uuidString).xlsx")
            try data.write(to: url)
            print(String(format: "generated synthetic:%@ (%.1f MB) in %.1f s", kind.rawValue,
                         Double(data.count) / 1_048_576, seconds(since: started)))
            return url
        }
    }

    /// 打开：读 xlsx、整本重算、建窗口、画出第一屏，分开量（墙上时间：打开时主线程一直在忙）。
    private func open(_ url: URL) async throws {
        var started = ContinuousClock.now
        var workbook: Workbook
        if DocumentLoader.isDelimitedText(url: url, typeName: nil) {
            workbook = try DocumentLoader.load(contentsOf: url).workbook
            record("open: read + recalc (csv)", [FrameSample(ms: milliseconds(since: started))])
        } else {
            workbook = try XLSXReader.readDocument(Data(contentsOf: url)).workbook
            record("open: read xlsx", [FrameSample(ms: milliseconds(since: started))])
            started = ContinuousClock.now
            Recalculator.recalculate(&workbook)
            record("open: recalculate", [FrameSample(ms: milliseconds(since: started))])
        }

        started = ContinuousClock.now
        DrawStats.reset()
        DrawStats.tracksDirtyRects = true
        session = SheetSession(workbook: workbook)
        if let name = request.sheetName, let index = workbook.sheetIndex(named: name) { session.showSheet(index) }
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
        record("open: window + first screen", [FrameSample(ms: milliseconds(since: started), builds: DrawStats.canvasBuilds,
                                                           panes: DrawStats.paneDraws, headers: DrawStats.headerDraws,
                                                           area: DrawStats.paneArea)])
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
        await idle { scroll(to: .zero) }
        await measure("scroll down (3 rows / frame)") { index in scroll(to: CGPoint(x: 0, y: CGFloat(index + 1) * rowStep)) }
        let bottom = clip.bounds.origin.y
        await measure("scroll up") { index in scroll(to: CGPoint(x: 0, y: bottom - CGFloat(index + 1) * rowStep)) }
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
        await idle { session.select(start) }
        await measure("arrow down (move selection)") { _ in session.moveCursor(rows: 1, columns: 0) }
        await idle { session.select(start) }
        await measure("arrow right") { _ in session.moveCursor(rows: 0, columns: 1) }
        await idle { session.select(start) }
        await measure("shift + arrow down (extend)") { _ in session.moveCursor(rows: 1, columns: 0, extend: true) }
        await idle { session.select(start) }
        await measure("drag select") { index in
            session.select(CellAddress(row: start.row + index, column: start.column + index / 4), extend: true)
        }
        var all: [FrameSample] = []
        var single: [FrameSample] = []
        for _ in 0..<Swift.min(request.frames, 8) {
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
        await measure("edit a cell + commit", frames: Swift.min(request.frames, 12), prepare: { [session] index in
            session?.editing = CellEditing(address: target, text: String(100 + index), origin: .typing)
        }) { _ in
            session.commitEditing()
        }
        await idle {
            session.editing = CellEditing(address: target, text: original, origin: .typing)
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
            for _ in 0..<Swift.min(request.frames, 10) {
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

    /// 选区、编辑从这里开始：冻结区右下的第一格。
    private var firstBodyCell: CellAddress {
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
        let started = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        action()
        await settle()
        for (view, rect) in DrawStats.dirty.values { draw(view, rect.intersection(view.visibleRect)) }
        DrawStats.dirty = [:]
        let used = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - started) / 1e6
        return FrameSample(ms: used, builds: DrawStats.canvasBuilds, panes: DrawStats.paneDraws,
                           headers: DrawStats.headerDraws, area: DrawStats.paneArea)
    }

    /// observeChanges 的回调是排在主线程上的 Task：先让一下，它们就排在前面跑完（主线程上的 Task 先来先跑）。
    /// 再睡一小会儿，run loop 走到「快睡了」那一步，SwiftUI 的更新在那时做；最后把自动布局排完。
    private func settle() async {
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
    private func gridViews(in view: NSView) -> [NSView] {
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
        print("(milliseconds of main-thread CPU per frame; open rows are wall-clock)")
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
