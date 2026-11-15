import Foundation

// 坏文件触发的崩溃和超时也要能报告；只在自检的子进程里运行这些输入。
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--formula-hunt-case" {
    formulaHuntCase(CommandLine.arguments[2])
    finishChecks()
}
if CommandLine.arguments.contains("--formula-hunt") {
    formulaHuntChecks()
    finishChecks()
}

// 全部自检的入口（设计第十二节）。每一块写在自己的 *Checks.swift 里，这里只按顺序调用。
// 跑法：swift run --arch arm64 SkySheetChecks（或 scripts/check-all.sh，CI 跑的也是它）。

zipChecks()
formatChecks()
formulaChecks()
circularChecks()
functionChecks()
formulaHuntChecks()
financialChecks()
xlsxReadChecks()
editingChecks()
rowColumnChecks()
xlsxWriteChecks()
structureLockChecks()
aiPropertiesChecks()
safetyStoreChecks()
aiCoreChecks()
mcpChecks()
claudeCodeConfigChecks()
claudeDesktopConfigChecks()
goldenLoanChecks()
displayChecks()
csvChecks()
performanceChecks()
largeSheetChecks()
selectionSumChecks()
exactTextChecks()
developerToolChecks()
finishChecks()
