import SkySheetCore
import SwiftUI

/// 窗口顶上那条横幅（设计 8.3 节）：AI 在改这个工作簿时显示「Claude Code 在改…」，这一轮结束后显示「改了 N 处」
/// 和「撤销这一轮」。只在这一轮改到的窗口里出现；没有 AI 活动时什么都不画（高度是 0）。
struct AIBanner: View {
    let session: SheetSession

    var body: some View {
        let ai = AISession.shared
        if ai.phase != .idle, ai.touched.contains(ObjectIdentifier(session)) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                if ai.phase == .working {
                    Text("\(ai.clientName) is working · \(ai.changeCount) changes so far")
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("\(ai.clientName) made \(ai.changeCount) changes. Nothing is saved until you press ⌘S.")
                }
                Spacer(minLength: 8)
                Button("Undo This Round") { ai.undoRound(in: session) }
                    .help("Put the workbook back the way it was before this round of AI changes. ⌘Z brings them back.")
                Button {
                    ai.dismiss(session)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Hide this and the highlights")
            }
            .font(.system(size: 12))
            .controlSize(.small)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.purple.opacity(0.08))
        }
    }
}

/// AI 的 sheet 的署名（页签上的提示）：谁建的、最后谁改的。
enum AIByline {
    static func text(_ authorship: AIAuthorship) -> String {
        var lines = [line(String(localized: "Created by"), authorship.created)]
        if let last = authorship.lastChanged { lines.append(line(String(localized: "Last changed by"), last)) }
        return lines.joined(separator: "\n")
    }

    private static func line(_ verb: String, _ mark: AIAuthorship.Mark) -> String {
        let who: String = switch mark.author {
        case .user: String(localized: "you")
        case .ai(let client, let model): model.map { "\(client) (\($0))" } ?? client
        }
        return "\(verb) \(who), \(mark.date.formatted(date: .abbreviated, time: .shortened))"
    }
}
