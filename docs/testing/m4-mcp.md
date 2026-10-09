# M4 MCP：真机检查清单

> 自检够不着的部分（设计第十二节）：和真的 Claude Code 对话、窗口里的横幅和页签、连接按钮。v0.3.0 起每次发版前走一遍，
> M2、M3 的清单照旧。
>
> 2026-10-09 开发时已经自动走过的标了「已自动测」：用 JSON-RPC 直接跟包里的 skysheet-mcp 说话走完 14 个工具，
> 又用 `claude -p`（临时配置、只挂 SkySheet、Sonnet）问了一遍「这几笔分期哪笔最贵」，它建了新 sheet、写了引用 Loan 的
> RATE 公式、答对了（招行e招贷1期 约 3.756%）。

## 准备

- [ ] 装上 v0.3.0；拿 `Fixtures/loan.xlsx` 或自己表格的**副本**来试。
- [ ] 设置（⌘,）→ Claude Code 那一行是「Not connected」→ 点 Connect → 变成「Connected」。
      `~/.claude/settings.json` 的 permissions.allow 里多了 `mcp__skysheet`，旁边有一份 `settings.json.skysheet-backup`。
- [ ] 新开一个 Claude Code 会话，`/mcp` 里能看到 skysheet 和 14 个工具。

## 三类典型问题（M4 的验收）

- [ ] 「算一下我这几笔分期的实际年化利率，哪笔最贵？」：出来一张紫色页签的新 sheet，页签小标写 Claude，格子里是引用
      Loan 的公式（点开能看到 `=RATE(Loan!C5,…)`），Loan 一个字没动。（已自动测）
- [ ] 「哪种贷款方式更合理？」（等额本息 / 等额本金 / 先息后本的对比）：结果写进新 sheet，有每月还款和总利息。
- [ ] 「和我现在每个月的还款比，我应该贷多少、多少利率的贷款？」：AI 先 get_status 看你选中的格子，算完写进新 sheet。
- [ ] 让它「把 Loan 表里的某个数改一下」：它不直接改，先复制一份（add_sheet copy_from）再改副本。（已自动测：拒绝改原表）

## 窗口里

- [ ] AI 改的时候窗口顶上出现横幅「Claude Code is working · N changes so far」，30 秒没动静变成「made N changes」。（已自动测）
- [ ] AI 改过的格子淡紫色高亮；点横幅的 ✕ 横幅和高亮一起消失。
- [ ] 「Undo This Round」：这一轮的改动全部退掉，⌘Z 又回来。
- [ ] 鼠标停在 AI 的页签上：显示「Created by Claude Code (claude-…), 日期」；自己改一格 AI 的 sheet 以后多一行「Last changed by you」。
- [ ] 页签右键：原始 sheet 有「Let AI Edit This Sheet」，AI 的 sheet 有「Mark as Original Data」。
- [ ] AI 打开文件、写东西时，SkySheet 不抢键盘：你在 Claude Code 里打字不会被打断。
- [ ] ⌘S 存了以后关掉再打开：AI 的 sheet 还是紫色页签、小标还在。腾讯文档打开存过的文件：AI 的 sheet 页签是紫色的。

## 边边角角

- [ ] 退出 SkySheet 再问 Claude 一个问题：SkySheet 在后台自己打开（没有「打开」面板），Claude 说「刚启动，要重新 open_file」。（已自动测）
- [ ] 让 Claude 存一份副本（save_copy）到已经有的文件名：它被拒绝、换个名字。（已自动测）
- [ ] 让 Claude 用 Python 分析（export_sheet 给它一个 csv 路径），结果用 add_sheet from_csv 带回来。
- [ ] Claude 写了算不了的函数：结果里有 errors，它会换一种写法（端到端时它碰到过 ROW、RANK，v0.3.0 已经补上）。
