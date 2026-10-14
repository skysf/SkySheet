# M4 MCP：真机检查清单

> 自检够不着的部分（设计第十二节）：和真的 Claude Code、Claude 桌面版对话、窗口里的横幅和页签、连接按钮。v0.3.0 起每次发版前走一遍，
> M2、M3 的清单照旧。
>
> 2026-10-09 开发时已经自动走过的标了「已自动测」：用 JSON-RPC 直接跟包里的 skysheet-mcp 说话走完 14 个工具，
> 又用 `claude -p`（临时配置、只挂 SkySheet、Sonnet）问了一遍「这几笔分期哪笔最贵」，它建了新 sheet、写了引用 Loan 的
> RATE 公式、答对了（招行e招贷1期 约 3.756%）。

## 准备

- [ ] 装上要发的那一版；拿 `Fixtures/loan.xlsx` 或自己表格的**副本**来试。
- [ ] 设置（⌘,）→ Claude Code 那一行是「Not connected」→ 点 Connect → 变成「Connected」。
      `~/.claude/settings.json` 的 permissions.allow 里多了 `mcp__skysheet`，旁边有一份 `settings.json.skysheet-backup`。
      `diff ~/.claude/settings.json.skysheet-backup ~/.claude/settings.json` 只差这一行（和上一行末尾的逗号）；
      原来就有 allow 列表的话，点 Disconnect 再 diff，一个字节不差（v0.3.1 起）。
- [ ] 新开一个 Claude Code 会话，`/mcp` 里能看到 skysheet 和 14 个工具。

## Claude 桌面版的聊天（2026-10-09 加，设计 9.5 节）

> 别在桌面版的 Code 页里做这一节：要退出 Claude，那个会话会一起被关掉。

- [ ] Claude 没开时：设置 → Claude Desktop 那一行「Not connected」→ Connect →「Connected」。
      `~/Library/Application Support/Claude/claude_desktop_config.json` 末尾多了 `mcpServers.skysheet`，旁边有一份
      `claude_desktop_config.json.skysheet-backup`；`ls -l` 两个都是 `-rw-------`；和备份 `diff` 只差这几行。
- [ ] 打开 Claude、新开一个聊天：工具里有 skysheet 的 14 个工具。问「打开 loan.xlsx 的副本，哪笔分期最贵？」：
      第一次用每个工具会问，选 Always allow；新 sheet 的页签小标写 Claude（写的是别的就记下来，那是桌面版报的客户端名）。
- [ ] Claude 开着时点 Connect：状态变成「Restart Claude to finish」，提示让你退出再打开。先在 Claude 里开一个 Code 会话
      （它会写一次配置，把 skysheet 那项冲掉），再 ⌘Q：SkySheet 的提示变成「Connected. Open Claude…」、状态「Connected」，
      配置里那一项又在了；打开 Claude，skysheet 在。
- [ ] Claude 开着时点 Disconnect：「Restart Claude to finish」→ ⌘Q Claude →「Disconnected.」；配置里没有 skysheet 了
      （mcpServers 剩 `{}` 或别的 server），别的字节没动。
- [ ] 桌面版的 Code 页里 `/mcp`：skysheet 是 Claude Code 那一行连的，和这一行无关。

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
