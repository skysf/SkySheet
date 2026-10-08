import AppKit
import SkySheetCore

/// 页签右键菜单里的几件事：改名、复制、删除（设计第 16 条）。要弹框的都挂在窗口上（sheet 形式），不挡别的窗口。
@MainActor
enum SheetCommands {
    static func rename(_ index: Int, in session: SheetSession, window: NSWindow?, proposed: String? = nil) {
        guard let window, session.workbook.sheets.indices.contains(index) else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Rename Sheet")
        alert.informativeText = String(localized: "Formulas that refer to this sheet will use the new name.")
        let field = NSTextField(string: proposed ?? session.workbook.sheets[index].name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Rename"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue
            do {
                try session.renameSheet(index, to: name)
            } catch let SheetEditError.invalidName(problem) {
                // 名字不行：说清楚为什么，再让用户改（带着刚才输入的）。
                explain(message(for: problem), in: window) { rename(index, in: session, window: window, proposed: name) }
            } catch {
                explain(error.localizedDescription, in: window)
            }
        }
    }

    static func duplicate(_ index: Int, in session: SheetSession) {
        guard session.workbook.sheets.indices.contains(index) else { return }
        session.duplicateSheet(index)
    }

    /// 有内容的 sheet 先确认一下。删了可以 ⌘Z 撤销，直到关掉文档。
    static func delete(_ index: Int, in session: SheetSession, window: NSWindow?) {
        guard let window, session.workbook.sheets.indices.contains(index) else { return }
        let sheet = session.workbook.sheets[index]
        func perform() {
            do {
                try session.deleteSheet(index)
            } catch SheetEditError.lastVisibleSheet {
                explain(String(localized: "A workbook must keep at least one visible sheet."), in: window)
            } catch {
                explain(error.localizedDescription, in: window)
            }
        }
        guard !sheet.cells.isEmpty else { return perform() }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Delete the sheet “\(sheet.name)”?")
        alert.informativeText = String(localized: "You can undo this with ⌘Z until you close the document.")
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { perform() }
        }
    }

    static func message(for problem: SheetName.Problem) -> String {
        switch problem {
        case .empty: String(localized: "The sheet name can't be empty.")
        case .tooLong: String(localized: "Sheet names can be at most 31 characters long.")
        case .invalidCharacter(let character): String(localized: "Sheet names can't contain “\(String(character))”.")
        case .apostropheAtEdge: String(localized: "Sheet names can't begin or end with an apostrophe.")
        case .reserved: String(localized: "“History” is a name Excel reserves for itself.")
        case .duplicate: String(localized: "Another sheet already has this name.")
        }
    }

    private static func explain(_ text: String, in window: NSWindow, then next: (@MainActor () -> Void)? = nil) {
        let alert = NSAlert()
        alert.messageText = text
        alert.addButton(withTitle: String(localized: "OK"))
        alert.beginSheetModal(for: window) { _ in next?() }
    }
}
