import AppKit

// 对比度和绘图断言共用光栅入口，像素坐标与表格的向下 y 轴保持一致。
@MainActor
func renderPixels(width: Int, height: Int, _ draw: () -> Void) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: width * 4, bitsPerPixel: 32)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
    context.cgContext.translateBy(x: 0, y: CGFloat(height))
    context.cgContext.scaleBy(x: 1, y: -1)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

