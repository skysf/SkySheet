import Foundation

/// 崩溃和超时输入用子进程隔离；其余断言直接运行，避免为每组普通公式重复启动进程。
@MainActor
func boundedCheckCase(_ name: String) {
    switch name {
    case "largeTextOffset": largeTextOffsetChecks()
    case "dateOverflow": dateOverflowChecks()
    case "dateMonthOverflow": dateMonthOverflowChecks()
    case "dateDayOverflow": dateDayOverflowChecks()
    case "edateOverflow": edateOverflowChecks()
    case "eomonthOverflow": eomonthOverflowChecks()
    case "serialOverflow": serialOverflowChecks()
    case "boundaryDates": boundaryDatesChecks()
    case "subsecond15": subsecond15Checks()
    case "bareCurrencyInput": bareCurrencyInputChecks()
    case "inputTimeOverflow": inputTimeOverflowChecks()
    case "largeDateExport": largeDateExportChecks()
    case "csvTimeOverflow": csvTimeOverflowChecks()
    case "cumulativeBound": cumulativeBoundChecks()
    case "boundaryCumulative": boundaryCumulativeChecks()
    case "fractionOverflow": fractionOverflowChecks()
    case "fractionPerformance": fractionPerformanceChecks()
    case "criteriaShape": criteriaShapeChecks()
    case "lookupShape": lookupShapeChecks()
    case "whitespaceInput": whitespaceInputChecks()
    case "csvWhitespace": csvWhitespaceChecks()
    case "jsonNumberText": jsonNumberTextChecks()
    default: fail("unknown bounded check \(name)")
    }
}

@MainActor
func boundedCheck(_ name: String) {
    group("bounded: \(name)") {
        let directory = try makeTemporaryDirectory()
        let log = directory.appendingPathComponent("output")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--bounded-check", name]
        process.standardOutput = output
        process.standardError = output
        var environment = ProcessInfo.processInfo.environment
        environment["SWIFT_BACKTRACE"] = "enable=no"
        process.environment = environment
        try process.run()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        let timedOut = process.isRunning
        if timedOut { process.terminate() }
        process.waitUntilExit()
        try output.close()
        let details = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        check(!timedOut && process.terminationReason == .exit && process.terminationStatus == 0,
              "\(name): \(timedOut ? "timeout" : "exit \(process.terminationStatus)")\n\(details.prefix(3000))")
    }
}
