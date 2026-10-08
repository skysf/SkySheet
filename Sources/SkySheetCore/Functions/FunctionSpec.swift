import Foundation

/// 一个函数：名字、参数个数、怎么算。所有函数登记在一张表里（设计 5.2 节）。
struct FunctionSpec: Sendable {
    let name: String
    let arguments: ClosedRange<Int>
    let evaluate: @Sendable (FunctionArguments) throws(CellError) -> CellValue

    init(_ name: String, _ arguments: ClosedRange<Int>,
         _ evaluate: @escaping @Sendable (FunctionArguments) throws(CellError) -> CellValue) {
        self.name = name
        self.arguments = arguments
        self.evaluate = evaluate
    }

    /// Excel 一个函数最多 255 个参数。
    static let many = 255
}

/// 第一版支持的函数（设计 5.3 节）。清单外的函数：公式原文和文件里的缓存值照样保留、照样显示，标「未重算」。
public enum FunctionLibrary {
    static let specs: [String: FunctionSpec] = {
        let groups = [MathFunctions.all, StatisticalFunctions.all, ConditionalFunctions.all, LogicalFunctions.all,
                      LookupFunctions.all, DateFunctions.all, TextFunctions.all, FinancialFunctions.all]
        var table: [String: FunctionSpec] = [:]
        for spec in groups.joined() {
            precondition(table[spec.name] == nil, "function \(spec.name) registered twice")
            table[spec.name] = spec
        }
        return table
    }()

    static func spec(named name: String) -> FunctionSpec? {
        specs[name]
    }

    /// 支持的函数名，按字母排。给 AI 看、给自检对账用。
    public static var names: [String] {
        specs.keys.sorted()
    }
}
