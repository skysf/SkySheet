import AppKit
import SkySheetCore
import SkySheetDisplay
import SkySheetFiles

/// 核对局部重画（`SkySheet --benchmark 文件 --benchmark-only verify`，2026-11-14）。
///
/// 选区一变只重画经过的那几行（SpreadsheetView.invalidateSelection）：重画的范围少了一块，屏幕上就会留下旧的选区框；
/// 边放得不对，旁边格子画出界的那一点会缺。截图模式每次都整块重画，看不出这些，所以在这里另外核对：
/// 每个格子视图留一张「屏幕」位图，只按标脏的区域往上画（和系统在屏幕上做的一样）；每一步之后再整块重画一张，
/// 两张逐字节比。一样才对。主区滚动时照系统的做法：原来的内容整块挪过去，只画新露出来的部分（挪的距离不是整像素的
/// 那一步就整块重画、不比）。
extension Benchmark {
    /// 一块视图的「屏幕」：看得见的那一块，按视图坐标 `visible` 对齐。
    private final class Screen {
        let visible: CGRect
        let context: CGContext

        init?(visible: CGRect, scale: CGFloat) {
            let width = Int((visible.width * scale).rounded())
            let height = Int((visible.height * scale).rounded())
            guard width > 0, height > 0,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
            self.visible = visible
            self.context = context
        }

        /// 两张「屏幕」是不是一样。只比整像素的部分：视图的边落在半个像素上时（缩放成 1.37 这种），最边上那一排像素
        /// 只盖了一部分，混进去的是底下原来的颜色，屏幕上本来就是这样，和重画画得对不对无关。
        func matches(_ other: Screen, scale: CGFloat) -> Bool {
            let rows = min(context.height, Int((visible.height * scale).rounded(.down)))
            let bytes = min(context.bytesPerRow, Int((visible.width * scale).rounded(.down)) * 4)
            guard let mine = context.data, let theirs = other.context.data else { return false }
            for row in 0..<rows where memcmp(mine + row * context.bytesPerRow, theirs + row * other.context.bytesPerRow, bytes) != 0 {
                return false
            }
            return true
        }

        /// 调试用：存成 PNG（环境变量 SKYSHEET_VERIFY_DUMP 给了目录才存）。
        func dump(_ name: String) {
            guard let directory = ProcessInfo.processInfo.environment["SKYSHEET_VERIFY_DUMP"] else { return }
            dump(name: directory + "/" + name)
        }

        func dump(name path: String) {
            let data = NSMutableData()
            guard let image = context.makeImage(),
                  let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return }
            Benchmark.writeDump(data as Data, to: URL(fileURLWithPath: path + ".png"))
        }
    }

    /// 核对一遍；返回对不上的步数（也打印出来）。
    @discardableResult
    func verifyPartialRedraws() async -> Int {
        var mismatches = 0
        var checked = 0
        for zoom in [1.0, 1.37] {
            await settleAfter { session.setZoom(zoom) }
            var screens: [ObjectIdentifier: Screen] = [:]
            func resync(_ view: NSView) {
                guard let screen = Screen(visible: view.visibleRect, scale: scale) else { return }
                render(view, view.visibleRect, into: screen)
                screens[ObjectIdentifier(view)] = screen
            }
            for view in gridViews(in: spreadsheet) { resync(view) }
            for (name, action) in steps() {
                DrawStats.dirty = [:]
                action()
                await settle()
                let dirty = DrawStats.dirty
                DrawStats.dirty = [:]
                for view in gridViews(in: spreadsheet) {
                    let key = ObjectIdentifier(view)
                    guard var screen = screens[key] else { continue }
                    if screen.visible != view.visibleRect {
                        // 主区滚了：系统把原来的内容挪过去，新露出来的部分标脏重画（exposeScrolledArea 记下的）。
                        guard let moved = shifted(screen, to: view.visibleRect) else {
                            resync(view)
                            continue
                        }
                        screen = moved
                        screens[key] = moved
                    }
                    let before = screen.context.makeImage()
                    if let rect = dirty[key]?.rect.intersection(view.visibleRect), !rect.isEmpty {
                        render(view, rect, into: screen)
                    }
                    guard let fresh = Screen(visible: view.visibleRect, scale: scale) else { continue }
                    render(view, view.visibleRect, into: fresh)
                    checked += 1
                    // 调试用：每一步整块重画的样子都存下来（SKYSHEET_VERIFY_ALL 给了目录才存），拿去和改之前的版本逐张比。
                    if let directory = ProcessInfo.processInfo.environment["SKYSHEET_VERIFY_ALL"] {
                        fresh.dump(name: String(format: "%@/%03d-%@", directory, checked, "\(type(of: view))"))
                    }
                    if !fresh.matches(screen, scale: scale) {
                        mismatches += 1
                        print("MISMATCH zoom \(zoom) after \(name) in \(type(of: view)) \(view.frame.integral)"
                              + " dirty \(dirty[key].map { "\($0.rect)" } ?? "none") visible \(view.visibleRect)")
                        screen.dump("mismatch-\(mismatches)-screen")
                        fresh.dump("mismatch-\(mismatches)-fresh")
                        if let directory = ProcessInfo.processInfo.environment["SKYSHEET_VERIFY_DUMP"],
                           let rep = view.bitmapImageRepForCachingDisplay(in: view.visibleRect) {
                            view.cacheDisplay(in: view.visibleRect, to: rep)
                            if let png = rep.representation(using: .png, properties: [:]) {
                                Self.writeDump(png, to: URL(fileURLWithPath: directory)
                                    .appendingPathComponent("mismatch-\(mismatches)-appkit.png"))
                            }
                        }
                        if let before, let previous = Screen(visible: screen.visible, scale: scale) {
                            previous.context.draw(before, in: CGRect(x: 0, y: 0, width: before.width, height: before.height))
                            previous.dump("mismatch-\(mismatches)-before")
                        }
                        resync(view)
                    }
                }
            }
        }
        await settleAfter { session.setZoom(1) }
        print("verify: \(checked) view comparisons, \(mismatches) mismatches")
        return mismatches
    }

    /// 要核对的选区变化：点格子、方向键、Shift 拉、整行整列、全选；合并单元格的表上点进合并单元格。都在看得见的范围里，
    /// 不让表滚动。
    private func steps() -> [(String, () -> Void)] {
        let start = firstBodyCell
        let session = session!
        var steps: [(String, () -> Void)] = [("nothing", {})]
        let cells = [(0, 0), (1, 0), (1, 1), (5, 2), (3, 7), (12, 4), (20, 1), (8, 9), (0, 3), (15, 6)]
        for (row, column) in cells {
            let address = CellAddress(row: start.row + row, column: start.column + column)
            steps.append(("click \(address.a1)", { session.select(address) }))
        }
        for (rows, columns) in [(1, 0), (1, 0), (0, 1), (0, 1), (-1, 0), (0, -1), (2, 3)] {
            steps.append(("move \(rows),\(columns)", { session.moveCursor(rows: rows, columns: columns) }))
        }
        for (rows, columns) in [(1, 0), (1, 0), (0, 1), (3, 2), (-2, -1)] {
            steps.append(("extend \(rows),\(columns)", { session.moveCursor(rows: rows, columns: columns, extend: true) }))
        }
        steps.append(("whole column", { session.selectLines(.columns, through: start.column + 2, extend: false, crossIndex: start.row) }))
        steps.append(("whole columns", { session.selectLines(.columns, through: start.column + 4, extend: true, crossIndex: start.row) }))
        steps.append(("whole row", { session.selectLines(.rows, through: start.row + 3, extend: false, crossIndex: start.column) }))
        steps.append(("whole rows", { session.selectLines(.rows, through: start.row + 6, extend: true, crossIndex: start.column) }))
        steps.append(("click after rows", { session.select(CellAddress(row: start.row + 2, column: start.column + 2)) }))
        steps.append(("select all", { session.selectAll() }))
        steps.append(("click after all", { session.select(CellAddress(row: start.row + 9, column: start.column + 3)) }))
        // 滚动（主区挪过去，新露出来的条重画），滚完再点几格。
        let clip = spreadsheet.scrollView.contentView
        let scroller = spreadsheet.scrollView
        for (dx, dy) in [(0.0, 50.0), (0.0, 37.5), (64.0, 0.0), (32.5, 0.0), (0.0, -20.0), (-10.5, 0.0), (24.0, 61.0)] {
            steps.append(("scroll \(dx),\(dy)", {
                clip.scroll(to: CGPoint(x: max(0, clip.bounds.minX + dx), y: max(0, clip.bounds.minY + dy)))
                scroller.reflectScrolledClipView(clip)
            }))
            let address = CellAddress(row: start.row + 14, column: start.column + 4)
            steps.append(("click \(address.a1) after scroll", { session.select(address) }))
        }
        steps.append(("scroll back", {
            clip.scroll(to: .zero)
            scroller.reflectScrolledClipView(clip)
        }))
        // 改格子：数字、长文字、清掉（改过的格子要按新内容画，记着的旧样子不能用）。
        let edited = CellAddress(row: start.row + 3, column: start.column + 1)
        for text in ["12345.678", "A rather long piece of text that spills over", "-0.5", ""] {
            steps.append(("edit \(edited.a1) to \(text)", {
                session.select(edited)
                session.beginEditing(.typing, text: text)
                session.commitEditing()
            }))
        }
        // 换到别的表再换回来（换回来时接着用上一份画布），再改一格（改过的表换回来要按新内容画）。
        let here = session.sheetIndex
        if let other = session.tabIndices.first(where: { $0 != here }) {
            steps.append(("switch away", { session.showSheet(other) }))
            steps.append(("switch back", { session.showSheet(here) }))
            steps.append(("edit after switching back", {
                session.select(edited)
                session.beginEditing(.typing, text: "777")
                session.commitEditing()
            }))
            steps.append(("switch away again", { session.showSheet(other) }))
            steps.append(("switch back again", { session.showSheet(here) }))
        }
        // 极窄的列、极矮的行（2026-11-15，Codex 审 PR #10 时指出）：行号列标的字比那一条宽（高），往两边伸出去。选区移进
        // 移出时，伸出去的那部分要跟着重画；从旁边伸进重画范围的字也要补上。一列宽 0.1 个字符，一行、连着六行高 1 磅。
        let sheetIndex = session.sheetIndex
        let narrow = start.column + 3
        let low = start.row + 4
        let lows = (start.row + 8)...(start.row + 13)
        steps.append(("narrow column", {
            session.apply("Column Width") { $0.setColumnWidth(0.1, columns: narrow...narrow, sheet: sheetIndex) }
        }))
        steps.append(("short rows", {
            session.apply("Row Height") { workbook in
                workbook.setRowHeight(1, rows: low...low, sheet: sheetIndex)
                workbook.setRowHeight(1, rows: lows, sheet: sheetIndex)
            }
        }))
        let thin = [(start.row, narrow), (start.row, narrow - 3), (start.row + 2, narrow), (start.row + 2, narrow + 1),
                    (low, start.column + 1), (start.row + 1, start.column + 1)]
            + lows.map { ($0, start.column + 1) } + [(start.row + 20, start.column + 1), (lows.upperBound, narrow)]
        for (row, column) in thin {
            let address = CellAddress(row: row, column: column)
            steps.append(("click \(address.a1) near thin lines", { session.select(address) }))
        }
        steps.append(("whole narrow column", { session.selectLines(.columns, through: narrow, extend: false, crossIndex: start.row) }))
        steps.append(("whole short rows", {
            session.selectLines(.rows, through: lows.lowerBound, extend: false, crossIndex: start.column)
            session.selectLines(.rows, through: lows.upperBound, extend: true, crossIndex: start.column)
        }))
        steps.append(("click after thin lines", { session.select(CellAddress(row: start.row + 1, column: start.column + 1)) }))
        steps.append(("restore thin lines", {
            session.apply("Restore") { workbook in
                workbook.setColumnWidth(nil, columns: narrow...narrow, sheet: sheetIndex)
                workbook.setRowHeight(nil, rows: low...low, sheet: sheetIndex)
                workbook.setRowHeight(nil, rows: lows, sheet: sheetIndex)
            }
        }))
        // 合并单元格（有的话）：点进去、点出来。
        for merge in session.sheet.merges.prefix(40) where merge.end.row < start.row + 25 && merge.end.column < start.column + 10 {
            steps.append(("click in merge \(merge.a1)", { session.select(merge.end) }))
            steps.append(("click below merge \(merge.a1)", {
                session.select(CellAddress(row: merge.end.row + 1, column: merge.start.column))
            }))
        }
        // 活动格跨过画布边界后要先扩展再滚动，扩展也不能让局部重画留下旧像素。
        if let geometry = spreadsheet.canvas?.geometry {
            let beyond = CellAddress(row: min(geometry.rowCount + 2, CellAddress.maxRows - 1),
                                     column: min(geometry.columnCount + 2, CellAddress.maxColumns - 1))
            steps.append(("cursor beyond canvas", { session.select(beyond) }))
            steps.append(("move after canvas growth", { session.moveCursor(rows: 1, columns: 1) }))
            steps.append(("return after canvas growth", { session.select(start) }))
        }
        return steps
    }

    /// 调试用的图（SKYSHEET_VERIFY_DUMP、SKYSHEET_VERIFY_ALL）只写新文件（NewFile）：目录里已经有同名的就不写、
    /// 打印一句，不覆盖。要重存换一个空目录。
    nonisolated static func writeDump(_ data: Data, to url: URL) {
        do {
            try NewFile.write(data, to: url)
        } catch {
            print("verify dump not written: \(error)")
        }
    }

    /// 主区滚动后的「屏幕」：原来的内容挪到新位置。大小变了、挪的不是整像素，就是 nil（整块重画）。
    private func shifted(_ screen: Screen, to visible: CGRect) -> Screen? {
        guard visible.size == screen.visible.size, let image = screen.context.makeImage(),
              let moved = Screen(visible: visible, scale: scale) else { return nil }
        let dx = (screen.visible.minX - visible.minX) * scale
        let dy = (screen.visible.minY - visible.minY) * scale
        guard dx == dx.rounded(), dy == dy.rounded() else { return nil }
        moved.context.draw(image, in: CGRect(x: dx, y: -dy, width: CGFloat(image.width), height: CGFloat(image.height)))
        return moved
    }

    private func settleAfter(_ action: () -> Void) async {
        action()
        await settle()
        DrawStats.dirty = [:]
    }

    /// 像系统那样把视图 `rect` 这一块画进「屏幕」：视图坐标的 `screen.visible.origin` 对着位图左上角，裁到 `rect`。
    /// 系统重画的区域按屏幕像素往外取整（标脏的边落在半个像素上也是整个像素重画），这里一样。
    private func render(_ view: NSView, _ dirty: CGRect, into screen: Screen) {
        let origin = screen.visible.origin
        let minX = ((dirty.minX - origin.x) * scale).rounded(.down) / scale + origin.x
        let minY = ((dirty.minY - origin.y) * scale).rounded(.down) / scale + origin.y
        let maxX = ((dirty.maxX - origin.x) * scale).rounded(.up) / scale + origin.x
        let maxY = ((dirty.maxY - origin.y) * scale).rounded(.up) / scale + origin.y
        let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let context = screen.context
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: view.isFlipped)
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        if view.isFlipped {
            // 用位图真正的高度翻转：视图上边对着第一排像素，取过整的重画边才落在像素边上。
            context.translateBy(x: 0, y: CGFloat(context.height) / scale)
            context.scaleBy(x: 1, y: -1)
        }
        context.translateBy(x: -screen.visible.minX, y: -screen.visible.minY)
        context.clip(to: rect)
        view.draw(rect)
        context.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
    }
}
