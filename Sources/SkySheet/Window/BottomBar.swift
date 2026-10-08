import SkySheetCore
import SkySheetDisplay
import SwiftUI

/// 底栏：sheet 页签，右边是选中区域的平均值、计数、合计（和 Excel 底部那行一样），再右边是缩放比例。
struct BottomBar: View {
    let session: SheetSession

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(session.tabIndices, id: \.self) { index in
                        SheetTab(sheet: session.workbook.sheets[index], isSelected: index == session.sheetIndex) {
                            session.showSheet(index)
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
            Spacer(minLength: 12)
            Text(summary)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text("\(Int((session.zoom * 100).rounded()))%")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
                .padding(.trailing, 10)
        }
        .frame(height: 28)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// 选了不止一格才显示。数字按活动格的格式显示（活动格是 ¥ 格式，合计也是 ¥）。
    private var summary: String {
        let range = session.selection.range
        // 只选了一个合并单元格也算「一格」，和 Excel 一样不显示合计。
        guard range.rowCount * range.columnCount > 1, !session.sheet.merges.contains(range) else { return "" }
        let totals = SelectionSummary(cells: session.sheet.cells, range: range)
        guard totals.count > 0 else { return "" }
        guard totals.numericCount > 0 else { return "Count: \(totals.count)" }
        let style = session.sheet.cells[session.selection.cursor]?.styleIndex ?? 0
        var code = session.workbook.styles.formatCode(forStyle: style)
        if ValueFormatter.isDateFormat(code) || code == "@" { code = "General" }
        func show(_ number: Decimal) -> String { ValueFormatter.format(.number(number), code: code).text }
        let average = totals.average.map { "Average: \(show($0))    " } ?? ""
        return "\(average)Count: \(totals.count)    Sum: \(show(totals.sum))"
    }
}

/// 一个页签。文件里给 sheet 设了页签颜色的，在下边画一道。
private struct SheetTab: View {
    let sheet: Sheet
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(sheet.name)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(isSelected ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                .overlay(alignment: .bottom) {
                    if let color = tabColor {
                        Rectangle().fill(color).frame(height: 3)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    /// 白色的页签颜色（腾讯文档常写 FFFFFFFF）等于没有。
    private var tabColor: Color? {
        guard let hex = sheet.tabColor, let rgb = RGBAColor(hex: hex), rgb != .white else { return nil }
        return Color(nsColor: NSColor(rgb))
    }
}
