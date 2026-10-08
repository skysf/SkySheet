import Foundation
import SkyZip

/// 存不了 xlsx 的原因。任何一种都发生在替换原文件之前，原文件不动（设计第十节第 3 条）。
public enum XLSXWriteError: Error, Equatable, Sendable {
    /// 原文件是 Strict Open XML 格式：读得了，在它上面改着写回去还不支持。
    case strictFormat
    /// 原包里我们要改的某个部件拆不开（XML 不完整），没法在它上面改。
    case unreadablePart(String)
    /// 样式只能往后加。已有的样式被改了是程序的错，宁可不存。
    case existingStylesChanged
    case zip(ZipError)
    /// 写出来的文件读回来和内存里对不上（第三道保险）。附带说明是哪里。
    case verificationFailed(String)
}
