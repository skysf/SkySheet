import SkySheetCore
import SwiftUI

/// 公式栏：活动格的地址，和它里面真正存的东西（公式原文，或者没格式化的值）。M2 只看不改。
/// 我们算不了的公式（设计 5.3 节「未重算」）在右边标出来，鼠标停上去看原因。
struct FormulaBar: View {
    let session: SheetSession

    var body: some View {
        let cursor = session.selection.cursor
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
            Text(cell.map { Self.rawText($0, styles: session.workbook.styles) } ?? "")
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if case .notRecalculated(let reason)? = cell?.formula?.status {
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

    /// 公式显示原文；日期显示成日期；别的数字显示全精度（不按格式四舍五入），和 Excel 的公式栏一样。
    static func rawText(_ cell: Cell, styles: SkySheetCore.StyleTable) -> String {
        if let formula = cell.formula { return "=" + formula.source }
        switch cell.value {
        case .empty: return ""
        case .text(let text): return text
        case .bool(let flag): return flag ? "TRUE" : "FALSE"
        case .error(let error): return error.code
        case .number(let number):
            let code = styles.formatCode(forStyle: cell.styleIndex)
            guard ValueFormatter.isDateFormat(code) else { return ValueFormatter.general(number) }
            let dateCode = DecimalMath.isInteger(number) ? "yyyy/m/d" : "yyyy/m/d h:mm:ss"
            return ValueFormatter.format(cell.value, code: dateCode).text
        }
    }
}
