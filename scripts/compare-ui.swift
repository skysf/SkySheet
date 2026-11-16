import AppKit
import ImageIO

// PNG 的压缩字节会变；统一解成 sRGB 像素再逐点比较，差异位置和前后图一起留给人工核对。
let arguments = CommandLine.arguments
guard arguments.count == 4 else { fatalError("Usage: compare-ui before-dir after-dir new-report-dir") }
let before = URL(fileURLWithPath: arguments[1])
let after = URL(fileURLWithPath: arguments[2])
let report = URL(fileURLWithPath: arguments[3])
guard !FileManager.default.fileExists(atPath: report.path) else { fatalError("Output already exists") }
try FileManager.default.createDirectory(at: report, withIntermediateDirectories: true)

func load(_ url: URL) -> (CGImage, [UInt8]) {
    let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    pixels.withUnsafeMutableBytes { bytes in
        let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return (image, pixels)
}

var results: [[String: Any]] = []
for file in try FileManager.default.contentsOfDirectory(atPath: before.path).filter({ $0.hasSuffix(".png") }).sorted() {
    let (old, a) = load(before.appendingPathComponent(file))
    let (new, b) = load(after.appendingPathComponent(file))
    guard old.width == new.width, old.height == new.height else { fatalError("Image dimensions differ: \(file)") }
    let w = old.width, h = old.height
    var count = 0, left = w, right = 0, top = h, bottom = 0
    var changedRows: [Int] = []
    var mask = [UInt8](repeating: 255, count: a.count)
    for y in 0..<h {
        var changed = false
        for x in 0..<w {
            let i = (y * w + x) * 4
            if a[i..<(i + 4)] != b[i..<(i + 4)] {
                count += 1; changed = true
                left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
                mask[i] = 255; mask[i + 1] = 0; mask[i + 2] = 0
            }
        }
        if changed { changedRows.append(y) }
    }
    var result: [String: Any] = ["file": file, "changedPixels": count, "width": w, "height": h]
    if count > 0 {
        let bounds = [left, top, right - left + 1, bottom - top + 1]
        result["bounds"] = bounds
        var bands: [[Int]] = []
        for y in changedRows {
            if let last = bands.last, y <= last[1] + 1 { bands[bands.count - 1][1] = y }
            else { bands.append([y, y]) }
        }
        result["rowBands"] = bands
        let crop = CGRect(x: max(0, left - 10), y: max(0, top - 10),
                          width: min(w, right + 11) - max(0, left - 10), height: min(h, bottom + 11) - max(0, top - 10))
        let data = Data(mask)
        let diff = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                           provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        // CGImage 裁剪用从上往下的像素坐标；三栏保持原像素，不插值、不缩放。
        let context = CGContext(data: nil, width: Int(crop.width) * 3, height: Int(crop.height), bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (index, image) in [old, new, diff].enumerated() {
            context.draw(image.cropping(to: crop)!, in: CGRect(x: CGFloat(index) * crop.width, y: 0, width: crop.width, height: crop.height))
        }
        let output = report.appendingPathComponent(file)
        let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("PNG write failed") }
    }
    results.append(result)
    print("\(file): \(count) changed pixels")
}
let json = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
try json.write(to: report.appendingPathComponent("pixels.json"), options: .withoutOverwriting)
