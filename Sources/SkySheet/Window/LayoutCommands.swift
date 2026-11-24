import AppKit
import SkySheetCore
import SkySheetFiles

/// 行列和格式命令要弹的框（2026-10-14 加）：输入列宽行高、合并前确认、为什么不能插删。都挂在窗口上（sheet 形式）。
@MainActor
enum LayoutCommands {
    /// 问一个列宽（Excel 的字符数，0–255）或行高（磅，0–409）。填 0 等于藏起来，和 Excel 一样。
    static func askSize(_ axis: SheetAxis, lines: ClosedRange<Int>, current: Double, in window: NSWindow?,
                        proposed: String? = nil, then apply: @escaping @MainActor (Double) -> Void) {
        guard let window else { return }
        let limit: Double = axis == .columns ? 255 : 409
        let alert = NSAlert()
        if axis == .columns {
            let first = CellAddress.columnName(lines.lowerBound)
            let name = lines.count == 1 ? first : "\(first)–\(CellAddress.columnName(lines.upperBound))"
            alert.messageText = String(localized: "Column Width")
            alert.informativeText = String(localized: "Width of column \(name), in characters of the default font (0–255).")
        } else {
            let name = lines.count == 1 ? "\(lines.lowerBound + 1)" : "\(lines.lowerBound + 1)–\(lines.upperBound + 1)"
            alert.messageText = String(localized: "Row Height")
            alert.informativeText = String(localized: "Height of row \(name), in points (0–409).")
        }
        let input = SizeInput()
        let field = NSTextField(string: proposed ?? input.string(current))
        field.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let text = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard let value = input.value(text), (0...limit).contains(value) else {
                let message = axis == .columns ? String(localized: "Enter a column width between 0 and 255.")
                                               : String(localized: "Enter a row height between 0 and 409.")
                explain(message + " " + String(localized: "Use a decimal number without thousands separators. If a period could be a thousands separator, use your local decimal separator instead."), in: window) {
                    askSize(axis, lines: lines, current: current, in: window, proposed: text, then: apply)
                }
                return
            }
            apply(value)
        }
    }

    static func explainCopyLimit(in window: NSWindow?) {
        guard let window else { return }
        explain(String(localized: "The selection is too large to copy. Select no more than \(CopyLimit.cells.formatted()) cells and try again."), in: window)
    }

    /// 合并会丢掉左上角以外的内容：先问一下。
    static func confirmMerge(keeping corner: CellAddress, losing count: Int, in window: NSWindow?,
                             then merge: @escaping @MainActor () -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Merge these cells?")
        alert.informativeText = count == 1
            ? String(localized: "Only the value in \(corner.a1) is kept; 1 other cell with content is cleared. You can undo this with ⌘Z.")
            : String(localized: "Only the value in \(corner.a1) is kept; \(count) other cells with content are cleared. You can undo this with ⌘Z.")
        alert.addButton(withTitle: String(localized: "Merge"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { merge() }
        }
    }

    /// 这张表不能插删行列：为什么，怎么办（复制一份改副本，副本不带那些东西）。
    static func explainLock(_ lock: StructureLock, sheet name: String, in window: NSWindow?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Rows and columns can't be inserted or deleted in “\(name)”")
        alert.informativeText = reason(lock) + "\n\n" + String(localized: """
            SkyFolio keeps these as they are but can't move them, so after inserting or deleting they would point at the \
            wrong cells in Excel or Tencent Docs. Duplicate the sheet and change the copy instead: copies don't carry them.
            """)
        alert.addButton(withTitle: String(localized: "OK"))
        alert.beginSheetModal(for: window)
    }

    static func reason(_ lock: StructureLock) -> String {
        switch lock {
        case .pictures: String(localized: "It has pictures or charts.")
        case .comments: String(localized: "It has comments.")
        case .conditionalFormatting: String(localized: "It has conditional formatting.")
        case .dataValidation: String(localized: "It has data validation (drop-down lists or input rules).")
        case .hyperlinks: String(localized: "It has hyperlinks.")
        case .filter: String(localized: "It has a filter or sort.")
        case .tables: String(localized: "It has Excel tables.")
        case .otherContent(let name): String(localized: "It has content SkyFolio keeps but doesn't understand (\(name)).")
        case .referencedElsewhere(let part): String(localized: "Another part of the file (\(part)) points at its cells.")
        }
    }

    /// 改动碰到了 SkySheet 写不回去的公式占着的格子，整个没做（工作簿没动；LockedFormulaChange）。
    static func explain(_ locked: LockedFormulaChange, in window: NSWindow?) {
        guard let window else { return }
        let message = switch locked.reason {
        case .sharedFormula(let range):
            String(localized: """
                \(locked.cell.a1) on “\(locked.sheet)” is part of a shared formula in \(range.a1) that SkyFolio can't work \
                out, so its cells can only be changed in Excel. Nothing was changed.
                """)
        case .dataTable(let range):
            String(localized: """
                \(locked.cell.a1) on “\(locked.sheet)” is part of the data table in \(range.a1), and a data table can't be \
                changed in part. Nothing was changed.
                """)
        }
        explain(message, in: window)
    }

    /// 插删没做成（工作簿没动）。
    static func explain(_ error: StructureEditError, in window: NSWindow?) {
        guard let window else { return }
        let message = switch error {
        case .wouldPushContentOffSheet:
            String(localized: "There's no room: inserting would push cells with content off the end of the sheet.")
        case .unreadableFormula(let sheet, let cell):
            String(localized: "SkyFolio can't read the formula in \(cell.a1) on “\(sheet)”, so it couldn't keep its references right. Nothing was changed.")
        case .unreadableName(let name):
            String(localized: "SkyFolio can't read the defined name “\(name)”, so it couldn't keep its references right. Nothing was changed.")
        case .splitsArrayFormula(let range):
            String(localized: "That would split the array formula in \(range.a1). Nothing was changed.")
        }
        explain(message, in: window)
    }

    private static func explain(_ text: String, in window: NSWindow, then next: (@MainActor () -> Void)? = nil) {
        let alert = NSAlert()
        alert.messageText = text
        alert.addButton(withTitle: String(localized: "OK"))
        alert.beginSheetModal(for: window) { _ in next?() }
    }
}

/// 数值框的显示和读取放在一起，地区回归无需弹出对话框。
struct SizeInput {
    private let formatter: NumberFormatter

    init(locale: Locale = .current) {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.isLenient = false
        self.formatter = formatter
    }

    func string(_ value: Double) -> String {
        formatter.string(from: NSNumber(value: value)) ?? ""
    }

    func value(_ text: String) -> Double? {
        var text = text.trimmingCharacters(in: .whitespaces)
        // 德语的 1.000 同时像标准小数和本地千分位；拒绝歧义，不能悄悄缩成 1。
        if formatter.groupingSeparator == ".",
           text.range(of: #"^[+-]?[0-9]{1,3}(\.[0-9]{3})+([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil { return nil }
        // 无歧义的点小数点仍兼容旧版，其余交给本地区的小数符号。
        if let value = Double(text), value.isFinite { return value }
        if text.hasPrefix("+") { text.removeFirst() }
        var range = NSRange(location: 0, length: (text as NSString).length)
        var result: AnyObject?
        do { try formatter.getObjectValue(&result, for: text, range: &range) }
        catch { return nil }
        // NumberFormatter 可能只吃掉前半段；原来的输入规则不接受尾随垃圾，地区修复也不能放宽它。
        guard range.location == 0, range.length == (text as NSString).length,
              let value = (result as? NSNumber)?.doubleValue, value.isFinite else { return nil }
        return value
    }
}
