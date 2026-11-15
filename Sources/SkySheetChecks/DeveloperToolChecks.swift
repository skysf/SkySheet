import Foundation
import SkySheetFiles

/// 开发工具（截图、测速、verify）只往新文件里写（2026-11-15）：命令行里的输出路径写错了、指到一个真的工作簿上，
/// 也绝不能把它换掉。原来 `--benchmark-file accounts.xlsx` 会把已有的工作簿直接换成合成表（Codex 审 PR #10 时发现，
/// 本机实跑复现：工作簿、`--benchmark-json`、`--snapshot-output`、verify 存的图都被覆盖了）。
/// 工具本身在 App 里、自检够不着；它们写文件都走 NewFile，启动时也先用它查一遍（App/main.swift），这里核对 NewFile。
@MainActor
func developerToolChecks() {
    group("developer tools: never overwrite an existing file") {
        let directory = try makeTemporaryDirectory()
        let existing = directory.appendingPathComponent("accounts.xlsx")
        let original = Data("the author's workbook".utf8)
        try original.write(to: existing)

        var refused = false
        do {
            try NewFile.write(Data("synthetic".utf8), to: existing)
        } catch is NewFile.AlreadyExists {
            refused = true
        }
        check(refused, "writing over an existing file is refused")
        checkEqual(try Data(contentsOf: existing), original, "the existing file is untouched")

        refused = false
        do {
            try NewFile.ensureAbsent([directory.appendingPathComponent("new.json"), existing])
        } catch let error as NewFile.AlreadyExists {
            refused = true
            checkEqual(error.url, existing, "the refusal names the existing file")
        }
        check(refused, "an existing output path is refused before anything runs")

        // 指向已有文件的符号链接也不能写穿过去。
        let link = directory.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: existing)
        refused = false
        do {
            try NewFile.write(Data("png".utf8), to: link)
        } catch is NewFile.AlreadyExists {
            refused = true
        }
        check(refused, "writing through a symbolic link to an existing file is refused")
        checkEqual(try Data(contentsOf: existing), original, "the link's target is untouched")

        // 新路径照常写。
        let fresh = directory.appendingPathComponent("results.json")
        try NewFile.ensureAbsent([fresh])
        try NewFile.write(Data("{}".utf8), to: fresh)
        checkEqual(try Data(contentsOf: fresh), Data("{}".utf8), "a new file is written")
    }
}
