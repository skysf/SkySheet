import Foundation

/// 按 Unicode 标量（UTF-8 字节）逐个比的字符串：做缓存的键、判断「没变」时用它（2026-11-15）。
///
/// Swift 的 String 相等按「规范等价」算：é（U+00E9）和 e + U+0301 是同一个字符串，做字典的键也是同一个键。可公式切词
/// 按标量来（U+0301 不是字母，`Cafe\u{301}!A1` 读不出来，`Café!A1` 是一个引用）；字体量字、画字也按标量来（Verdana、
/// Georgia 这类字体里两种写法宽度不同，2026-11-15 本机实测）。按 String 做键，先记进去的那一种就替后来的那一种答了
/// （Codex 审 PR #10 时指出解析缓存这一处，自检 exactTextChecks 复现）。
public struct ExactText: Hashable, Sendable {
    public let string: String

    public init(_ string: String) {
        self.string = string
    }

    public static func == (lhs: ExactText, rhs: ExactText) -> Bool {
        lhs.string.utf8.count == rhs.string.utf8.count && lhs.string.utf8.elementsEqual(rhs.string.utf8)
    }

    public func hash(into hasher: inout Hasher) {
        var copy = string   // withUTF8 要 mutating；原生的字符串本来就是连续的 UTF-8，不会真的复制
        copy.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
    }
}
