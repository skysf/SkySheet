import AppKit
import SkySheetCore
import SwiftUI

/// 公式栏：活动格的地址，和它里面真正存的东西（公式原文，或者没格式化的值）。点进去可以改，
/// 和格内的编辑框是同一份文字（session.editing）。
/// 我们算不了的公式（设计 5.3 节「未重算」）在右边标出来，鼠标停上去看原因。
struct FormulaBar: View {
    let session: SheetSession

    var body: some View {
        let cursor = session.editing?.address ?? session.selection.cursor
        let cell = session.sheet.cells[cursor]
        HStack(spacing: 0) {
            Text(cursor.a1)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(width: 72, alignment: .leading)
                .padding(.leading, 10)
            Divider().frame(height: 16)
            Text("fx")
                .font(.system(size: 12, design: .serif).italic())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            FormulaField(session: session)
            Spacer(minLength: 8)
            if session.editing == nil, case .notRecalculated(let reason)? = cell?.formula?.status {
                Label("Not recalculated", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .help("SkySheet shows the value saved in the file: \(reason).")
                    .padding(.trailing, 10)
            }
        }
        .frame(height: 28)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// 公式栏里的文字框。用 AppKit 的 NSTextField：回车、Tab、Esc 要和格内编辑框一样处理。
private struct FormulaField: NSViewRepresentable {
    let session: SheetSession

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.cell?.allowsUndo = false
        field.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let text = session.editing?.text ?? session.rawText(at: session.selection.cursor)
        // 公式栏自己在打字时不回写，免得冲掉光标位置和输入法的拼音。
        let typingHere = field.currentEditor() != nil && session.editing?.origin == .formulaBar
        if !typingHere, field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let session: SheetSession

        init(session: SheetSession) {
            self.session = session
        }

        /// 开始打字（不是点进来那一下）：格内正在编辑的接着编，没有就从活动格开始。
        func controlTextDidBeginEditing(_ notification: Notification) {
            if session.editing == nil {
                session.beginEditing(.formulaBar)
            } else {
                session.editing?.origin = .formulaBar
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if session.editing == nil { session.beginEditing(.formulaBar) }
            session.editing?.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): finish { $0.commitEditing(rows: shift ? -1 : 1) }
            case #selector(NSResponder.insertTab(_:)): finish { $0.commitEditing(columns: 1) }
            case #selector(NSResponder.insertBacktab(_:)): finish { $0.commitEditing(columns: -1) }
            case #selector(NSResponder.cancelOperation(_:)): finish { $0.cancelEditing() }
            default: return false
            }
            return true
        }

        private func finish(_ action: (SheetSession) -> Void) {
            action(session)
            session.focusGrid?()
        }
    }
}
