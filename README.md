# SkySheet

一个给 AI 用的轻量 macOS 表格工具：打开 xlsx / csv 看数据，让 Claude Code 通过 MCP 读表、计算贷款和理财的数，
把结果写进新的 sheet，原始数据永远不动。

**状态：v0.3.1，第一个真正可用的版本。** 能打开、编辑、保存 xlsx 和 csv（保存有六道保险：只有 ⌘S 写回原文件、写完读回来
核对、第一次覆盖前备份、崩溃后能恢复、文件被别的程序改过先问）；Claude Code 通过 MCP（`skysheet`，14 个工具）读表、跑 SQL、
算公式，把结果写进紫色页签的新 sheet，原始 sheet 对它只读。设置（⌘,）里点「Connect」就连上 Claude Code。
设计见 [docs/plans/2026-10-08-skysheet-design.md](docs/plans/2026-10-08-skysheet-design.md)。

- macOS 15 起，Apple 芯片
- 零第三方依赖
- 许可证：AGPL-3.0

---

A lightweight macOS spreadsheet built for AI: open an xlsx or csv file, let Claude Code read and compute through MCP,
and get the results in new sheets while the original data stays untouched. Status: v0.3.1 opens, edits and saves
xlsx and csv files (backups, crash recovery, a read-back check on every save), and Claude Code connects through MCP
(`skysheet`, 14 tools; Settings → Connect).
