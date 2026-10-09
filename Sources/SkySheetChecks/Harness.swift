import Foundation

// MARK: - 极简断言
//
// 本机只有命令行工具，没有 XCTest，也没有 Swift Testing（设计第十二节，2026-10-08 实测），所以自己写。
// 失败只记下来接着跑，最后一起报：一次看全所有失败。

@MainActor
enum Checks {
    static var passed = 0
    static var failures: [String] = []
    static var currentGroup = ""
}

/// 一组检查。组里抛出的意外错误算这一组的一个失败，不中断后面的组。
@MainActor
func group(_ name: String, _ body: () throws -> Void) {
    Checks.currentGroup = name
    do {
        try body()
    } catch {
        fail("unexpected error: \(error)")
    }
}

@MainActor
func check(_ condition: Bool, _ message: @autoclosure () -> String, file: StaticString = #fileID, line: UInt = #line) {
    if condition {
        Checks.passed += 1
    } else {
        fail(message(), file: file, line: line)
    }
}

@MainActor
func checkEqual<T: Equatable>(
    _ actual: T, _ expected: T, _ message: @autoclosure () -> String = "",
    file: StaticString = #fileID, line: UInt = #line
) {
    check(actual == expected, "\(message()) got \(actual), expected \(expected)", file: file, line: line)
}

@MainActor
func fail(_ message: String, file: StaticString = #fileID, line: UInt = #line) {
    Checks.failures.append("[\(Checks.currentGroup)] \(file):\(line) \(message)")
}

/// 打印结果并退出：全过退出码 0，否则 1。临时目录在这里一起删掉（exit 不会跑 defer 和 deinit）。
@MainActor
func finishChecks() -> Never {
    try? FileManager.default.removeItem(at: temporaryRoot)
    for failure in Checks.failures {
        print("FAIL \(failure)")
    }
    if Checks.failures.isEmpty {
        print("All \(Checks.passed) checks passed")
        exit(0)
    }
    print("\(Checks.failures.count) failed, \(Checks.passed) passed")
    exit(1)
}

// MARK: - 文件和外部程序

/// 仓库根目录：从这个源文件往上三层（Sources/SkySheetChecks/Harness.swift）。本机和 CI 都成立。
let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

func fixtureURL(_ name: String) -> URL {
    repositoryRoot.appendingPathComponent("Fixtures").appendingPathComponent(name)
}

/// 这一次自检的临时目录都放在它下面，跑完由 `finishChecks` 整个删掉。以前每个目录单独放、没人删，
/// 本机每跑一次就在 $TMPDIR 里多留几个（2026-10-09 清出 84 个）。
private let temporaryRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("SkySheetChecks-\(UUID().uuidString)", isDirectory: true)

/// 每次调用新建一个空的临时目录。
func makeTemporaryDirectory() throws -> URL {
    let url = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// 跑一个系统自带的命令行工具，返回退出码（输出都丢掉）。
func runTool(_ path: String, _ arguments: [String], in directory: URL? = nil) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return -1
    }
    process.waitUntilExit()
    return process.terminationStatus
}
