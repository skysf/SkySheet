# SkyFolio

一个给 AI 用的轻量 macOS 表格工具：打开 xlsx / csv 看数据，让 Claude Code 通过 MCP 读表、计算贷款和理财的数，
把结果写进新的 sheet，原始数据永远不动。

Mac 和 SkyFolio 移动预览版在编辑提交后自动保存。关闭文件再打开，仍可从 Mac 的「File → Version History」或移动端的「… → Version History」恢复某一步。每次写回前都会核对生成的文件，首次覆盖前会备份原件。其他软件修改过原件时，自己的编辑保留在本机历史里。

Mac 上 AI 在获准的工作表中所做的改动默认也自动保存。历史会标出一段 AI 修改开始前的版本。设置中可单独开启 AI 保存确认，这时该工作簿继续将每一步记入历史，按 ⌘S 后一起写回文件。

CSV 和 TSV 交给其他软件时带第一张表的值。本机历史另外保留公式、样式和其他工作表，需要把这些内容带到另一台设备时可以另存为 xlsx。

Claude Code 通过 MCP（`skyfolio`，14 个工具）读表、跑 SQL、
算公式，把结果写进紫色页签的新 sheet，原始 sheet 对它只读。设置（⌘,）里点「Connect」就连上 Claude Code，
Claude 桌面版的聊天那一行同样一点（重启一次 Claude）。
设计见 [docs/plans/2026-10-08-skysheet-design.md](docs/plans/2026-10-08-skysheet-design.md)。

- Mac 支持 macOS 15 及以上、Apple 芯片。移动目标支持 iOS / iPadOS 18 及以上。
- 零第三方依赖
- 许可证：AGPL-3.0

---

A lightweight macOS spreadsheet built for AI: open an xlsx or csv file, let Claude Code read and compute through MCP,
and get the results in new sheets while the original sheets stay read-only to AI. Edits autosave with local version
history, backups and read-back verification. The same workbook engine powers SkyFolio on iPhone and iPad. Claude Code or the Claude desktop
app's chats connect through MCP (`skyfolio`, 14 tools; Settings → Connect).
