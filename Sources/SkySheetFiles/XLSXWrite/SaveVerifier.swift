import Foundation
import SkySheetCore

/// 第三道保险（设计第十节）：写出来的文件当成别人的文件重新读一遍，和内存里的工作簿逐项比对；
/// 原样照抄的部件逐字节比对。全对才算写好；任何一处不对就报错，原文件不动。
///
/// 字一律逐个 Unicode 标量比（ExactText）：Swift 的 String 按「规范等价」算相等，写出来的「K」变成开尔文符号 U+212A、
/// 「豈」U+8C48 变成兼容汉字 U+F900，按 String 比照样通过（PR #11 审查发现，2026-11-16 修）。
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
            guard ExactText(memory.name) == ExactText(reread.name), memory.visibility == reread.visibility else {
                throw XLSXWriteError.verificationFailed("Sheet “\(memory.name)” was saved with a different name or visibility.")
            }
            // 没改过的 sheet 是原字节照抄的，上面已经逐字节比过。
            if result.regeneratedSheets.contains(memory.id) {
                // 哪些公式该照原样写回 `<f>`，按内存里这张表的记录重新算一遍（不拿写的那一边算好的）。
                let kept = try FormulaElements.kept(in: memory, stored: memory.storedFormulas)
                try compare(memory, reread, kept: kept, written: reread.storedFormulas)
            }
        }
        // 哪些是 AI 的 sheet、谁写的：按写进文件的样子比（时间只记到秒）。
        guard exact(AIProperties.properties(of: saved)) == exact(AIProperties.properties(of: workbook)) else {
            throw XLSXWriteError.verificationFailed("Which sheets belong to AI doesn't match after saving.")
        }
        guard saved.styles == workbook.styles, exact(strings(in: saved.styles)) == exact(strings(in: workbook.styles)) else {
            throw XLSXWriteError.verificationFailed("Cell styles don't match after saving.")
        }
        guard saved.definedNames == workbook.definedNames,
              exact(saved.definedNames.flatMap { strings(in: $0) }) == exact(workbook.definedNames.flatMap { strings(in: $0) })
        else {
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

    /// 重新生成的 sheet：每个格子（值、公式、`<f>` 的类型和属性、样式）、列宽、行高、冻结窗格、合并单元格、页签颜色。
    /// `kept` 是该照原样写回 `<f>` 的格子，`written` 是读回来的文件里每格 `<f>` 带的属性。
    private static func compare(_ memory: Sheet, _ saved: Sheet, kept: [CellAddress: StoredFormula],
                                written: [CellAddress: StoredFormula]) throws(XLSXWriteError) {
        func fail(_ what: String) -> XLSXWriteError {
            XLSXWriteError.verificationFailed("Sheet “\(memory.name)”: \(what) doesn't match after saving.")
        }
        var expected: [CellAddress: CellImage] = [:]
        memory.cells.forEach { address, cell in
            var image = cell
            var attributes: [String: String] = [:]
            if let formula = cell.formula {
                if let stored = kept[address] {
                    attributes = stored.attributes
                } else if formula.source.isEmpty {
                    image.formula = nil   // 原文是空的、没有原来的 <f> 可照写：只写值（WorksheetWriter）
                } else {
                    attributes = FormulaElements.plainAttributes(formula)
                }
            }
            guard image != Cell() else { return }
            expected[address] = CellImage(image, formulaAttributes: attributes)
        }
        var actual: [CellAddress: CellImage] = [:]
        saved.cells.forEach { address, cell in
            actual[address] = CellImage(cell, formulaAttributes: written[address]?.attributes ?? [:])
        }
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
        guard memory.tabColor.map(ExactText.init) == saved.tabColor.map(ExactText.init) else { throw fail("tab color") }
        // 内存里没写默认行高的，文件里补的是按默认字体算的那个（WorksheetWriter），不算不一样。
        guard memory.defaultRowHeight == nil || memory.defaultRowHeight == saved.defaultRowHeight,
              memory.defaultColumnWidth == saved.defaultColumnWidth else {
            throw fail("default sizes")
        }
    }

    // MARK: - 逐个标量比

    private static func exact(_ values: [String?]) -> [ExactText?] {
        values.map { $0.map(ExactText.init) }
    }

    private static func exact(_ dictionary: [String: String]) -> [ExactText: ExactText] {
        Dictionary(dictionary.map { (ExactText($0.key), ExactText($0.value)) }, uniquingKeysWith: { first, _ in first })
    }

    /// 样式表里所有的字，按固定的先后排：结构由 `==` 比过，这里只补上逐个标量比。
    private static func strings(in styles: StyleTable) -> [String?] {
        func color(_ color: StyleColor?) -> String? {
            if case .rgb(let rgb)? = color?.source { return rgb }
            return nil
        }
        var result: [String?] = styles.customNumberFormats.sorted { $0.key < $1.key }.map(\.value)
        for format in styles.cellFormats { result += [format.horizontalAlignment, format.verticalAlignment] }
        for font in styles.fonts { result += [font.name, color(font.color)] }
        for fill in styles.fills { result += [fill.pattern, color(fill.foreground), color(fill.background)] }
        for border in styles.borders {
            for edge in [border.left, border.right, border.top, border.bottom] { result += [edge?.style, color(edge?.color)] }
        }
        return result
    }

    private static func strings(in name: DefinedName) -> [String?] {
        [name.name, name.formula] + name.extraAttributes.sorted { $0.key < $1.key }.flatMap { [$0.key, $0.value] }
    }
}

/// 一个格子写进文件后应有的样子：数字按写进文件的写法（17 位有效数字）比，公式按标准写法比，
/// 循环引用的格子不写值（设计 5.5 节）。字、公式、`<f>` 的属性都逐个标量比（ExactText）。
private struct CellImage: Equatable {
    let value: ExactText
    let formula: ExactText?
    let arrayRange: CellRange?
    let formulaAttributes: [ExactText: ExactText]
    let style: Int

    init(_ cell: Cell, formulaAttributes: [String: String]) {
        let text: String
        switch cell.value {
        case .empty: text = ""
        case .number(let number): text = "n" + XLSXNumber.text(number)
        case .text(let string): text = "s" + string
        case .bool(let flag): text = flag ? "b1" : "b0"
        case .error(let error): text = cell.formula != nil && error == .circular ? "" : "e" + error.code
        }
        value = ExactText(text)
        formula = cell.formula.map { ExactText(FormulaRewriter.storageForm($0.source)) }
        arrayRange = cell.formula?.arrayRange
        self.formulaAttributes = Dictionary(formulaAttributes.map { (ExactText($0.key), ExactText($0.value)) },
                                            uniquingKeysWith: { first, _ in first })
        style = cell.styleIndex
    }
}
