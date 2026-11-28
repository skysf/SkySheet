import Foundation

/// 直接检查值的类型，避免普通函数的数字转换把 "50"、TRUE 和空格都当成数字。
enum InformationFunctions {
    static let all: [FunctionSpec] = [
        test("ISNUMBER") { $0.number != nil },
        test("ISTEXT", isText),
        test("ISNONTEXT") { !isText($0) },
        test("ISBLANK") { $0.isEmpty },
        test("ISLOGICAL") { if case .bool = $0 { true } else { false } },
        test("ISERROR") { if case .error = $0 { true } else { false } },
        test("ISERR") { if case .error(let error) = $0 { error != .na } else { false } },
        test("ISNA") { $0 == .error(.na) },
    ]

    private static func isText(_ value: CellValue) -> Bool {
        if case .text = value { return true }
        return false
    }

    private static func test(_ name: String, _ predicate: @escaping @Sendable (CellValue) -> Bool) -> FunctionSpec {
        FunctionSpec(name, 1...1) { .bool(predicate($0.scalar(0))) }
    }
}
