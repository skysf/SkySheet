import Foundation

// 全部自检的入口（设计第十二节）。每一块写在自己的 *Checks.swift 里，这里只按顺序调用。
// 跑法：swift run --arch arm64 SkySheetChecks（或 scripts/check-all.sh，CI 跑的也是它）。

zipChecks()
formatChecks()
formulaChecks()
functionChecks()
financialChecks()
xlsxReadChecks()
editingChecks()
xlsxWriteChecks()
aiPropertiesChecks()
safetyStoreChecks()
aiCoreChecks()
mcpChecks()
claudeCodeConfigChecks()
goldenLoanChecks()
displayChecks()
csvChecks()
performanceChecks()
finishChecks()
