import SwiftUI

#if os(macOS)
import AppKit
public typealias FolioNativeColor = NSColor
#else
import UIKit
public typealias FolioNativeColor = UIColor
#endif

/// 取自文档袋图标的纸、朱红封套、桃色背景和靛蓝墨水。窗口配色与文件本身的样式各有自己的来源。
@MainActor
public enum FolioTheme {
    public static let paper = Swatch(0xFFF2E6, 0x302826)
    public static let header = Swatch(0xF7E3C5, 0x392D2A)
    public static let peach = Swatch(0xFECEAF, 0x5D3A30)
    public static let ink = Swatch(0x2C2E86, 0xFFEBDC)
    public static let secondaryInk = Swatch(0x664E49, 0xE1C5B6)
    public static let rule = Swatch(0xD4B5A2, 0x735B50)
    public static let accent = Swatch(0xD4230E, 0xFFA78B)

    public struct Swatch {
        public let light: FolioNativeColor
        public let dark: FolioNativeColor
        public let native: FolioNativeColor
        public var color: Color {
            #if os(macOS)
            Color(nsColor: native)
            #else
            Color(uiColor: native)
            #endif
        }

        fileprivate init(_ lightRGB: UInt32, _ darkRGB: UInt32) {
            let light = Self.rgb(lightRGB)
            let dark = Self.rgb(darkRGB)
            self.light = light
            self.dark = dark
            #if os(macOS)
            native = NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            }
            #else
            native = UIColor { traits in traits.userInterfaceStyle == .dark ? dark : light }
            #endif
        }

        private static func rgb(_ value: UInt32) -> FolioNativeColor {
            let red = CGFloat((value >> 16) & 255) / 255
            let green = CGFloat((value >> 8) & 255) / 255
            let blue = CGFloat(value & 255) / 255
            #if os(macOS)
            return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
            #else
            return UIColor(red: red, green: green, blue: blue, alpha: 1)
            #endif
        }
    }
}
