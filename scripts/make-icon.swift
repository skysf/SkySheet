import AppKit

// SkySheet 的图标：用代码画（仓库里不放二进制图标），只需要命令行工具。
//   swift scripts/make-icon.swift <输出的 .iconset 目录>
// build-app.sh 接着用 iconutil 合成 icns。
//
// 画的是：青绿色渐变的圆角方块上一张白纸，纸上是表格的网格，表头一行着色，选中的一格描一圈。

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "SkySheet.iconset"
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// 在 1024 × 1024 的画布上画（原点在左下）。
func drawIcon() {
    // macOS 图标栅格：内容 824 × 824，四周留 100。
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGradient(starting: color(0x14B8A6), ending: color(0x0F766E))?.draw(in: tilePath, angle: -90)

    let paper = NSRect(x: 222, y: 236, width: 580, height: 552)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, 0.25)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    color(0xFFFFFF).setFill()
    NSBezierPath(roundedRect: paper, xRadius: 36, yRadius: 36).fill()
    NSGraphicsContext.restoreGraphicsState()

    let inset = paper.insetBy(dx: 40, dy: 44)
    let columns = 4
    let rows = 5
    let cellWidth = inset.width / CGFloat(columns)
    let cellHeight = inset.height / CGFloat(rows)
    // 表头一行
    color(0xCCFBF1).setFill()
    NSRect(x: inset.minX, y: inset.maxY - cellHeight, width: inset.width, height: cellHeight).fill()
    // 网格
    let grid = NSBezierPath()
    for column in 0...columns {
        let x = inset.minX + CGFloat(column) * cellWidth
        grid.move(to: NSPoint(x: x, y: inset.minY))
        grid.line(to: NSPoint(x: x, y: inset.maxY))
    }
    for row in 0...rows {
        let y = inset.minY + CGFloat(row) * cellHeight
        grid.move(to: NSPoint(x: inset.minX, y: y))
        grid.line(to: NSPoint(x: inset.maxX, y: y))
    }
    grid.lineWidth = 8
    color(0x99D5CF).setStroke()
    grid.stroke()
    // 选中的一格
    let selected = NSRect(x: inset.minX + cellWidth * 2, y: inset.minY + cellHeight, width: cellWidth, height: cellHeight)
    let outline = NSBezierPath(roundedRect: selected.insetBy(dx: -4, dy: -4), xRadius: 8, yRadius: 8)
    outline.lineWidth = 22
    color(0xF59E0B).setStroke()
    outline.stroke()
}

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in sizes {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("cannot make a bitmap") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("cannot encode \(name)") }
    try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("\(name).png"))
}
print("icons written to \(output)")
