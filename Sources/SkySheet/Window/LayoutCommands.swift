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
        let field = NSTextField(string: proposed ?? current.formatted(.number.precision(.fractionLength(0...2)).grouping(.never)))
        field.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let text = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard let value = Double(text), (0...limit).contains(value) else {
                let message = axis == .columns ? String(localized: "Enter a column width between 0 and 255.")
                                               : String(localized: "Enter a row height between 0 and 409.")
                explain(message, in: window) {
                    askSize(axis, lines: lines, current: current, in: window, proposed: text, then: apply)
                }
                return
            }
            apply(value)
        }
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
            SkySheet keeps these as they are but can't move them, so after inserting or deleting they would point at the \
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
        case .otherContent(let name): String(localized: "It has content SkySheet keeps but doesn't understand (\(name)).")
        case .referencedElsewhere(let part): String(localized: "Another part of the file (\(part)) points at its cells.")
        }
    }

    /// 插删没做成（工作簿没动）。
    static func explain(_ error: StructureEditError, in window: NSWindow?) {
        guard let window else { return }
        let message = switch error {
        case .wouldPushContentOffSheet:
            String(localized: "There's no room: inserting would push cells with content off the end of the sheet.")
        case .unreadableFormula(let sheet, let cell):
            String(localized: "SkySheet can't read the formula in \(cell.a1) on “\(sheet)”, so it couldn't keep its references right. Nothing was changed.")
        case .unreadableName(let name):
            String(localized: "SkySheet can't read the defined name “\(name)”, so it couldn't keep its references right. Nothing was changed.")
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
