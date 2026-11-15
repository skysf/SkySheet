import Foundation

// 崩溃和超时输入隔离运行，普通断言留在当前进程。
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--bounded-check" {
    boundedCheckCase(CommandLine.arguments[2])
    finishChecks()
}
if CommandLine.arguments.contains("--table-blocks") {
    tableBlockRegressionChecks()
    finishChecks()
}

// 全部自检的入口（设计第十二节）。每一块写在自己的 *Checks.swift 里，这里只按顺序调用。
// 跑法：swift run --arch arm64 SkySheetChecks（或 scripts/check-all.sh，CI 跑的也是它）。

zipChecks()
formatChecks()
formulaChecks()
circularChecks()
functionChecks()
conditionalRegressionChecks()
textRegressionChecks()
tableBlockRegressionChecks()
dateRegressionChecks()
formatRegressionChecks()
lookupRegressionChecks()
inputRegressionChecks()
csvRegressionChecks()
financialRegressionChecks()
functionRegressionChecks()
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
