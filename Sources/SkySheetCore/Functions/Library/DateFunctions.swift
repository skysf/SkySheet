import Foundation

/// 日期函数。日期就是序列号（设计第四节），算法在 `DateMath` 里。
enum DateFunctions {
    static let all: [FunctionSpec] = [
        FunctionSpec("TODAY", 0...0, today),
        FunctionSpec("DATE", 3...3, date),
        FunctionSpec("YEAR", 1...1, year),
        FunctionSpec("MONTH", 1...1, month),
        FunctionSpec("DAY", 1...1, day),
        FunctionSpec("EDATE", 2...2, addMonths),
        FunctionSpec("EOMONTH", 2...2, endOfMonth),
        FunctionSpec("DATEDIF", 3...3, difference),
        FunctionSpec("DAYS", 2...2, days),
    ]

    private static func today(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        .number(Decimal(arguments.context.todaySerial))
    }

    private static func date(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        .number(Decimal(try DateMath.serial(year: try arguments.integer(0), month: try arguments.integer(1),
                                            day: try arguments.integer(2), system: arguments.context.dateSystem)))
    }

    private static func year(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        .number(Decimal(try civil(arguments, 0).year))
    }

    private static func month(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        .number(Decimal(try civil(arguments, 0).month))
    }

    private static func day(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        .number(Decimal(try civil(arguments, 0).day))
    }

    private static func addMonths(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        .number(Decimal(try DateMath.addMonths(try serial(arguments, 0), months: try arguments.integer(1),
                                               system: arguments.context.dateSystem)))
    }

    private static func endOfMonth(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        .number(Decimal(try DateMath.endOfMonth(try serial(arguments, 0), months: try arguments.integer(1),
                                                system: arguments.context.dateSystem)))
    }

    private static func difference(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        .number(Decimal(try DateMath.difference(from: try serial(arguments, 0), to: try serial(arguments, 1),
                                                unit: try arguments.text(2), system: arguments.context.dateSystem)))
    }

    private static func days(_ arguments: FunctionArguments) throws(CellError) -> CellValue {
        .number(Decimal(try serial(arguments, 0) - serial(arguments, 1)))
    }

    /// 日期参数：取整数部分（时刻不要），负数是 #NUM!。
    private static func serial(_ arguments: FunctionArguments, _ index: Int) throws(CellError) -> Int {
        let value = try arguments.number(index)
        guard value >= 0, let serial = DecimalMath.int(DecimalMath.floor(value)) else { throw CellError.num }
        return serial
    }

    private static func civil(_ arguments: FunctionArguments, _ index: Int) throws(CellError) -> CivilDate {
        try DateMath.civil(try serial(arguments, index), system: arguments.context.dateSystem)
    }
}
