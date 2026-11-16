import AppKit
import SkySheetCore
import SkySheetFiles

/// 测速模式（2026-11-14，设计 8.2 节「性能」）：
/// `SkySheet --benchmark synthetic:data|synthetic:formulas|synthetic:styles|文件.xlsx [--sheet 名字 | --sheet-index 2]
///  [--size 1280x800] [--frames 40] [--benchmark-only scroll|arrows|select|edit|resize|switch|verify] [--benchmark-scale 0.2]
///  [--benchmark-file 存合成表的路径.xlsx] [--benchmark-json 结果.json]`
/// `--benchmark-scale` 把合成的表按比例缩小（0.2 就是 2 万行），调试时跑得快；`--sheet-index` 按第几张（从 1 数）选表，
/// 不用在命令行里写 sheet 名。`--benchmark-only verify` 不计时，核对局部重画和整块重画画出来的一不一样（BenchmarkVerify），
/// arrows 超过 20 帧时先预热 20 帧，再循环走有效区域；scroll 保持历史默认行为。
/// `--benchmark-cycle-scroll` 才启用滚动的预热与 20 帧循环，新旧模式不能混着比较。
/// 对不上的打印 MISMATCH、以 1 退出。`--benchmark-file`、`--benchmark-json` 只写新文件：已经有东西就拒绝、以 1 退出（NewFile）。
///
/// 把作者说卡的六类动作（打开、滚动、移动选区、改格子、拖列宽行高、换 sheet 和缩放）各做若干帧，打印每类的中位数、
/// p95、最大值。合成的表先写成 xlsx 再打开：「打开」走的和双击文件是同一条路。
/// 量出来的数字要用 release 构建（`swift build -c release --arch arm64 --product SkySheet`），debug 的会误导。
///
/// 全程在后台：窗口不放上屏幕（OffscreenWindow），系统不会来画它，所以每一帧由这里照着屏幕上会发生的事来画——
/// 表格视图标脏的区域（DrawStats 记下来的），加上主区滚动时新露出来的那一条（系统滚动时只画新露出的部分，
/// 2026-11-14 量的时候窗口还放在屏幕外很远的地方 orderFront 着，对过：每帧画的面积就是新露出的条加上跟着动的冻结窗格）
/// ——画进一张位图。
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
    let sheetIndex: Int?
    let scale: Double
    let size: NSSize
    let frames: Int
    /// 合成的表存在哪（留着给截图模式比对用；必须是还没有的文件）；不给就写进临时目录，跑完删掉。
    let keepFile: URL?
    let json: URL?
    /// 只量某一类（scroll、select、edit、resize、switch），配合很多帧给 `sample` 采样用。
    let only: String?
    let cycleScroll: Bool

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
        sheetIndex = option("--sheet-index").flatMap(Int.init).map { $0 - 1 }
        scale = option("--benchmark-scale").flatMap(Double.init) ?? 1
        let parts = option("--size")?.split(separator: "x").compactMap { Double($0) } ?? []
        size = parts.count == 2 ? NSSize(width: parts[0], height: parts[1]) : NSSize(width: 1280, height: 800)
        frames = option("--frames").flatMap(Int.init) ?? 40
        keepFile = option("--benchmark-file").map { URL(fileURLWithPath: $0) }
        json = option("--benchmark-json").map { URL(fileURLWithPath: $0) }
        only = option("--benchmark-only")
        cycleScroll = arguments.contains("--benchmark-cycle-scroll")
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
                let benchmark = Benchmark(request: request)
                let results = try await benchmark.runAll()
                if let url = request.json {
                    let rows = results.map { ["name": $0.name, "median": $0.median, "p95": $0.p95, "max": $0.max,
                                              "frames": $0.frames.count] as [String: Any] }
                    let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
                    try NewFile.write(data, to: url)   // 不覆盖已有的文件（启动时也查过，App/main.swift）
                }
                // verify 对不上就以 1 退出，脚本里可以直接判断。
                exit(benchmark.verifyMismatches > 0 ? 1 : 0)
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
