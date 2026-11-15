import Foundation

/// 只新建、不覆盖的写文件（2026-11-15）。截图、测速、verify 这些开发工具往命令行给的路径写结果；路径写错了、指到一个
/// 真的工作簿上，也绝不能把原来的文件换掉（硬规矩第 2 条「原始数据永远不动」的精神）。原来 `--benchmark-file` 直接
/// `Data.write(to:)`，会把已有的工作簿换成合成表（Codex 审 PR #10 时发现，本机实跑复现）。
///
/// 两道：启动时先查一遍所有输出路径（`ensureAbsent`，什么都还没做就退出）；真写的时候用系统的「不覆盖」写法
/// （`.withoutOverwriting`，判断和新建是同一步，中间被别人抢先建了也不会盖掉）。符号链接也算已经存在。
public enum NewFile {
    public struct AlreadyExists: Error, CustomStringConvertible {
        public let url: URL
        public var description: String { "refusing to overwrite existing file \(url.path)" }
    }

    /// 写一个新文件；已经有了就抛 `AlreadyExists`，原来的文件一个字节不动。
    public static func write(_ data: Data, to url: URL) throws {
        if exists(url) { throw AlreadyExists(url: url) }
        do {
            try data.write(to: url, options: .withoutOverwriting)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            throw AlreadyExists(url: url)
        }
    }

    /// 这几个路径都还没有东西；有一个已经存在就抛 `AlreadyExists`（指出是哪一个）。
    public static func ensureAbsent(_ urls: [URL]) throws {
        if let taken = urls.first(where: exists) { throw AlreadyExists(url: taken) }
    }

    /// 路径上有没有东西：文件、目录、符号链接（指向的东西不在也算）。
    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }
}
