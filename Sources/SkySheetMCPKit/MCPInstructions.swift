import Foundation

// MARK: - 给 AI 的总说明（MCP 的 `instructions`）：一份目录（设计 9.4 节）
//
// 管什么：所有工具共用的东西 —— SkySheet 是什么、平常的顺序、几条要 AI **主动**做的规矩，和按需求分组的工具目录。
// 不管什么：某一个工具怎么用（写在它自己的说明里，Claude Code 用到那个工具才加载）。
//
// **Claude Code 只读前 2,048 个字符**（JavaScript 的字符串长度，超了静默截掉），Codex 要求前 512 个字符自成一体：
// 所以开头一段就是完整的最短用法。Claude Code 会话开始时只看得到工具名和这份说明，清单里的每个工具名都要在目录里
// （自检钉着：长度、开头、工具名、只用英文）。SrtFlow 的教训（设计 9.1 节第 6 条）。

public enum MCPInstructions {
    public static let text = """
    SkySheet is a spreadsheet app on the user's Mac; its window shows the workbook while you work. Usual order: \
    get_status (open workbooks, sheets, the user's selection) or open_file; describe_sheet to learn the layout; \
    read_range, query (SQL) or evaluate to get numbers; put results in a new sheet with add_sheet and write_cells; \
    show to point the user at them. Tool descriptions have the details.

    Rules:
    - Original sheets are read-only. Results go in new sheets (add_sheet). To change original data, add_sheet \
    copy_from=<sheet> and edit the copy.
    - Prefer formulas that reference the original cells, e.g. =RATE(Loan!C5,-Loan!F5,Loan!B5)*12, over typed-in \
    numbers, so the user can trace every result.
    - Python is fine for heavy analysis: export_sheet gives a CSV path; bring results back with add_sheet from_csv \
    or write_cells. Never open, change or save the user's .xlsx/.csv files with other programs.
    - Only open files the user named or these tools returned.
    - Nothing reaches the user's file until they press Cmd+S. save_copy only writes a new file.
    - A round of changes can be undone in one step (undo round=true).

    Tools by need:
    - Workbooks: get_status, open_file, save_copy
    - Read: describe_sheet, read_range, query, evaluate, export_sheet
    - Write (AI sheets only): add_sheet, write_cells, format_cells, edit_sheet, undo
    - Point the user: show
    """
}
