import Foundation
import SkySheetCore

/// 第三道保险（设计第十节）：写出来的文件当成别人的文件重新读一遍，和内存里的工作簿逐项比对；
/// 原样照抄的部件逐字节比对。全对才算写好；任何一处不对就报错，原文件不动。
public enum SaveVerifier {
    /// `data` 是从磁盘上读回来的临时文件。通过了返回读回来的文档：存完以后它就是新的「原包」。
    public static func verify(_ data: Data, written result: XLSXWriteResult, workbook: Workbook,
                              source: XLSXSource?) throws(XLSXWriteError) -> XLSXDocument {
        let document: XLSXDocument
        do {
            document = try XLSXReader.readDocument(data)
        } catch {
            throw XLSXWriteError.verificationFailed("The saved file can't be read back (\(error)).")
        }
        if let source { try compareCopies(result.copiedEntries, saved: document.source, original: source) }

        let saved = document.workbook
        guard saved.sheets.map(\.id) == workbook.sheets.map(\.id) else {
            throw XLSXWriteError.verificationFailed("The saved file has a different list of sheets.")
        }
        for (memory, reread) in zip(workbook.sheets, saved.sheets) {
            guard memory.name == reread.name, memory.visibility == reread.visibility else {
                throw XLSXWriteError.verificationFailed("Sheet “\(memory.name)” was saved with a different name or visibility.")
            }
            // 没改过的 sheet 是原字节照抄的，上面已经逐字节比过。
            if result.regeneratedSheets.contains(memory.id) { try compare(memory, reread) }
        }
        guard saved.styles == workbook.styles else {
            throw XLSXWriteError.verificationFailed("Cell styles don't match after saving.")
        }
        guard saved.definedNames == workbook.definedNames else {
            throw XLSXWriteError.verificationFailed("Defined names don't match after saving.")
        }
        guard saved.dateSystem == workbook.dateSystem else {
            throw XLSXWriteError.verificationFailed("The date system changed after saving.")
        }
        return document
    }

    /// 照抄的条目解压出来和原包里的一字不差（解压时顺带校验了 CRC）。
    private static func compareCopies(_ names: [String], saved: XLSXSource, original: XLSXSource) throws(XLSXWriteError) {
        for name in names {
            guard let before = original.package.zip.entry(named: name), let after = saved.package.zip.entry(named: name),
                  let beforeData = try? original.package.zip.contents(of: before),
                  let afterData = try? saved.package.zip.contents(of: after), beforeData == afterData
            else {
                throw XLSXWriteError.verificationFailed("Part \(name) wasn't copied over unchanged.")
            }
        }
    }

    /// 重新生成的 sheet：每个格子（值、公式、样式）、列宽、行高、冻结窗格、合并单元格、页签颜色。
    private static func compare(_ memory: Sheet, _ saved: Sheet) throws(XLSXWriteError) {
        func fail(_ what: String) -> XLSXWriteError {
            XLSXWriteError.verificationFailed("Sheet “\(memory.name)”: \(what) doesn't match after saving.")
        }
        var expected: [CellAddress: CellImage] = [:]
        memory.cells.forEach { address, cell in
            if cell != Cell() { expected[address] = CellImage(cell) }
        }
        var actual: [CellAddress: CellImage] = [:]
        saved.cells.forEach { address, cell in actual[address] = CellImage(cell) }
        if expected != actual {
            let address = Set(expected.keys).union(actual.keys).sorted().first { expected[$0] != actual[$0] }
            throw fail("cell \(address?.a1 ?? "?")")
        }
        let order: (ColumnFormat, ColumnFormat) -> Bool = { ($0.first, $0.last) < ($1.first, $1.last) }
        guard memory.columns.sorted(by: order) == saved.columns.sorted(by: order) else { throw fail("column widths") }
        let rows = memory.rowFormats.filter { $0.value.height != nil || $0.value.hidden || $0.value.styleIndex != nil }
        guard rows == saved.rowFormats else { throw fail("row heights") }
        func frozen(_ panes: FrozenPanes?) -> FrozenPanes? { panes.flatMap { $0.rows > 0 || $0.columns > 0 ? $0 : nil } }
        guard frozen(memory.frozen) == frozen(saved.frozen) else { throw fail("frozen panes") }
        guard memory.merges == saved.merges else { throw fail("merged cells") }
        guard memory.tabColor == saved.tabColor else { throw fail("tab color") }
        // 内存里没写默认行高的，文件里补的是按默认字体算的那个（WorksheetWriter），不算不一样。
        guard memory.defaultRowHeight == nil || memory.defaultRowHeight == saved.defaultRowHeight,
              memory.defaultColumnWidth == saved.defaultColumnWidth else {
            throw fail("default sizes")
        }
    }
}

/// 一个格子写进文件后应有的样子：数字按写进文件的写法（17 位有效数字）比，公式按标准写法比，
/// 循环引用的格子不写值（设计 5.5 节）。
private struct CellImage: Equatable {
    let value: String
    let formula: String?
    let arrayRange: CellRange?
    let style: Int

    init(_ cell: Cell) {
        switch cell.value {
        case .empty: value = ""
        case .number(let number): value = "n" + XLSXNumber.text(number)
        case .text(let text): value = "s" + text
        case .bool(let flag): value = flag ? "b1" : "b0"
        case .error(let error): value = cell.formula != nil && error == .circular ? "" : "e" + error.code
        }
        formula = cell.formula.map { FormulaRewriter.storageForm($0.source) }
        arrayRange = cell.formula?.arrayRange
        style = cell.styleIndex
    }
}
