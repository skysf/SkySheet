import CoreGraphics
import Foundation
import ImageIO

// macOS 的 iconset 和 iOS 资源目录共用一张方形母图。这里给 Mac 加留白和圆角，系统会给 iOS 的原图裁边。
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let artworkURL = root.appendingPathComponent("packaging/Assets.xcassets/AppIcon.appiconset/SkyFolio.png")
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "SkySheet.iconset", isDirectory: true)

guard let source = CGImageSourceCreateWithURL(artworkURL as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      properties[kCGImagePropertyPixelWidth] as? Int == 1024,
      properties[kCGImagePropertyPixelHeight] as? Int == 1024,
      properties[kCGImagePropertyHasAlpha] as? Bool != true else {
    fatalError("Expected an opaque 1024 × 1024 icon at \(artworkURL.path)")
}

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func writeIcon(pixels: Int, to target: URL) {
    // 沿用 Mac 图标的 1024 点栅格，图面占 824 点，每侧留 100 点透明区。
    let factor = CGFloat(pixels) / 1024
    let tile = CGRect(x: 100 * factor, y: 100 * factor, width: 824 * factor, height: 824 * factor)
    let radius = 185 * factor
    let outline = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: Int(ceil(tile.width))
    ]
    guard let artwork = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
          let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("Cannot render \(target.lastPathComponent)")
    }
    context.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    context.addPath(outline)
    context.clip()
    context.interpolationQuality = .high
    context.draw(artwork, in: tile)

    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(target as CFURL, "public.png" as CFString, 1, nil) else {
        fatalError("Cannot create \(target.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write \(target.path)") }
}

for points in [16, 32, 128, 256, 512] {
    for scale in 1...2 {
        let suffix = scale == 2 ? "@2x" : ""
        let name = "icon_\(points)x\(points)\(suffix).png"
        writeIcon(pixels: points * scale, to: output.appendingPathComponent(name))
    }
}
print("icons written to \(output.path)")
