import Foundation

/// 读写 zip 时的失败。xlsx 打不开时，界面上给用户看的话由上层按这里的分类来写。
public enum ZipError: Error, Equatable, Sendable {
    /// 找不到中央目录结尾：根本不是 zip（有密码的 xlsx 就是这样，它其实是一个加密的 OLE 文件）。
    case notAZip
    /// 某个字段指向文件外面：文件被截断或者损坏。
    case truncated
    /// zip64、加密条目、没见过的压缩方式。xlsx 里不会出现，出现了就明确拒绝，不猜。
    case unsupported(String)
    /// 解压失败或者 CRC 对不上。
    case corrupt(String)
    /// 写 zip 时同一个名字加了两次。
    case duplicateEntry(String)
}
