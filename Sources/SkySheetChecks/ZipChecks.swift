import Foundation
import SkyZip

/// 设计第十二节第 4 条：我们写的包能通过系统 unzip -t；系统 zip、ditto 打的包我们能读；样例能完整解开。
@MainActor
func zipChecks() {
    group("zip: write then read back") {
        // 伪随机字节压不小，应该自动退回 stored；重复的文字压得很小，应该是 deflated。
        var seed: UInt32 = 12345
        let noise = Data((0..<65_536).map { _ -> UInt8 in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return UInt8(seed >> 24)
        })
        let text = Data(String(repeating: "SkySheet 贷款表 ", count: 5000).utf8)
        var writer = ZipWriter()
        try writer.addDirectory("xl/")
        try writer.addFile("xl/text.xml", contents: text)
        try writer.addFile("xl/noise.bin", contents: noise)
        try writer.addFile("xl/empty.xml", contents: Data())
        try writer.addFile("数据/表.xml", contents: Data("中文名字".utf8))
        do {
            try writer.addFile("xl/text.xml", contents: Data())
            fail("duplicate name accepted")
        } catch let error as ZipError {
            checkEqual(error, ZipError.duplicateEntry("xl/text.xml"), "duplicate name")
        }
        let zip = try ZipArchive(data: writer.finished())
        checkEqual(zip.entries.map(\.name), ["xl/", "xl/text.xml", "xl/noise.bin", "xl/empty.xml", "数据/表.xml"], "order")
        checkEqual(try zip.contents(ofEntryNamed: "xl/text.xml"), text, "text round trip")
        checkEqual(try zip.contents(ofEntryNamed: "xl/noise.bin"), noise, "noise round trip")
        checkEqual(try zip.contents(ofEntryNamed: "xl/empty.xml"), Data(), "empty round trip")
        checkEqual(try zip.contents(ofEntryNamed: "数据/表.xml"), Data("中文名字".utf8), "unicode name")
        checkEqual(zip.entry(named: "xl/noise.bin")?.method, .stored, "incompressible stored")
        checkEqual(zip.entry(named: "xl/text.xml")?.method, .deflated, "compressible deflated")
        check((zip.entry(named: "xl/text.xml")?.compressedSize ?? .max) < text.count / 10, "text compresses well")
        check(zip.entry(named: "xl/")?.isDirectory == true, "directory entry")

        let folder = try makeTemporaryDirectory()
        let file = folder.appendingPathComponent("ours.zip")
        try writer.finished().write(to: file)
        checkEqual(runTool("/usr/bin/unzip", ["-tq", file.path]), 0, "system unzip -t accepts our zip")
    }

    group("zip: read archives made by system tools") {
        let folder = try makeTemporaryDirectory()
        let source = folder.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let a = Data(String(repeating: "hello zip ", count: 300).utf8)
        let b = Data("第二个文件".utf8)
        try a.write(to: source.appendingPathComponent("a.txt"))
        try b.write(to: source.appendingPathComponent("sub/b.txt"))

        checkEqual(runTool("/usr/bin/zip", ["-q", "-r", "-X", "../by-zip.zip", "."], in: source), 0, "zip tool ran")
        let byZip = try ZipArchive(data: Data(contentsOf: folder.appendingPathComponent("by-zip.zip")))
        checkEqual(try byZip.contents(ofEntryNamed: "a.txt"), a, "zip: a.txt")
        checkEqual(try byZip.contents(ofEntryNamed: "sub/b.txt"), b, "zip: sub/b.txt")

        // ditto 写的是带数据描述符的条目（本地文件头里大小是 0），必须按中央目录读。
        checkEqual(runTool("/usr/bin/ditto", ["-c", "-k", source.path, folder.appendingPathComponent("by-ditto.zip").path]), 0, "ditto ran")
        let byDitto = try ZipArchive(data: Data(contentsOf: folder.appendingPathComponent("by-ditto.zip")))
        checkEqual(try byDitto.contents(ofEntryNamed: "a.txt"), a, "ditto: a.txt")
        checkEqual(try byDitto.contents(ofEntryNamed: "sub/b.txt"), b, "ditto: sub/b.txt")
    }

    group("zip: the loan.xlsx fixture") {
        let zip = try ZipArchive(data: Data(contentsOf: fixtureURL("loan.xlsx")))
        checkEqual(zip.entries.count, 24, "entry count (Tencent Docs writes directory entries too)")
        checkEqual(zip.entries.last?.name, "[Content_Types].xml", "content types is last, as Tencent Docs writes it")
        for entry in zip.entries where !entry.isDirectory {
            let data = try zip.contents(of: entry)
            checkEqual(data.count, entry.uncompressedSize, "size of \(entry.name)")
        }
        let workbook = try zip.contents(ofEntryNamed: "xl/workbook.xml") ?? Data()
        check(String(decoding: workbook, as: UTF8.self).contains("name=\"Loan\""), "workbook names the Loan sheet")
    }

    group("zip: damaged input") {
        do {
            _ = try ZipArchive(data: Data("definitely not a zip file, just text".utf8))
            fail("text accepted as zip")
        } catch let error as ZipError {
            checkEqual(error, ZipError.notAZip, "not a zip")
        }
        var writer = ZipWriter()
        try writer.addFile("x.txt", contents: Data(String(repeating: "abc", count: 1000).utf8))
        var bytes = [UInt8](writer.finished())
        bytes[40] ^= 0xFF  // 改坏压缩数据里的一个字节
        let damaged = try ZipArchive(data: Data(bytes))
        do {
            _ = try damaged.contents(ofEntryNamed: "x.txt")
            fail("damaged data accepted")
        } catch let error as ZipError {
            if case .corrupt = error {} else { fail("expected corrupt, got \(error)") }
        }
    }
}
