# SkyFolio

所有 AI（Claude、Codex 或别的）共用这一份说明；CLAUDE.md 只有一句话，把这份引进来。
这一页只放每次都得看的几条和一张文档目录，细节按需去对应的文档里找。要改哪方面，就改那份文档，别把细节写回这里，免得它越来越长。

SkyFolio 是给 AI 用的轻量表格 App，读写 xlsx / csv：Mac 版为主，iPhone、iPad 共用同一套核心。Claude Code、Codex 这些 AI
通过 MCP（`skyfolio`）读表、计算，把结果写进新 sheet；原始数据永远不动。

## 开工前

- **待办只记在 `TODO.md`**（作者 2026-11-26 定，别处不另列）：开工前先读；第一次回复作者时，用两三句话提醒他还剩什么没做；
  做完一项就从那里删掉，新发现、暂时不修的问题也记进去。
- **现在在哪**：M5 打磨中，里程碑见设计第十三节，每完成一个就改这一行。本机装的是 Mac 版 SkyFolio 0.3.11
  （`ai.skylu.skyfolio`，Developer ID 签名、已公证），Codex 通过 `skyfolio-mcp` 连接。
- **本机和 CI 的分工**（作者 2026-11-26 定）：默认在本机编译，只跑和改动相关的小测试；完整自检、UI 套件、模拟器这些重的放 CI。
  细节见 `docs/development.md`。
- 和作者沟通用中文；注释和文档用中文，写「为什么」；界面文字只用英文。

## 硬规矩

1. `SampleData/` 是作者的真实财务数据：永远不进仓库，也不进 issue、PR、提交说明；测试只用 `Fixtures/`。
2. 原始 sheet 对 AI 只读（设计第 12 条）；保存的六道保险（设计第十节）任何改动都不许绕开。
3. 不认识的东西原样保留：xlsx 里读不懂的部件和元素、公式原文、文件里的缓存值，一律不改、不丢。
4. 不通过包管理器引第三方库（`Package.swift` 没有 `dependencies`）。别人的开源代码只能按设计第 7 条复制进 `ThirdParty/<项目名>/`：
   许可证和 AGPL-3.0 兼容，带原许可证和 `SOURCE.md`（出处、提交、改了什么），从此当自己的代码维护。
5. 签名只经 `scripts/signing/` 里的脚本（`sign-app.sh` 签名，`notarize.sh` 公证）。证书按发布渠道选（作者 2026-11-26 定，细节见 `docs/release.md`）：
   商店外的 Mac 版用 Developer ID 并公证，上 App Store 用 Apple Distribution。签名和公证只在本机做，私钥和凭据不进 CI、
   不进仓库。证书永远不重建（包括旧的「Skylu Signing」），这台机器上没有就停下来问作者。
6. MCP：小程序的 stdout 只写 MCP 消息；工具清单只有一份（`SkySheetMCPKit`）；给模型看的文字只用英文，总说明不超过
   2,048 个字符。
7. main 禁止直推：开分支、提 PR，CI 绿了再合。

## 文档目录

| 要找 | 看哪里 |
|---|---|
| 所有没做完的事 | `TODO.md` |
| 每条决定和理由（下称「设计」） | `docs/plans/2026-10-08-skysheet-design.md` |
| 2026-11-15、11-16 定的计划：同一个 App 还开 Word 和 Markdown、改名 SkyFolio、以后给别人用（下称「新方案」）。按设计第十三节的里程碑一步步做，还没做的别当成已经有了 | `docs/plans/2026-11-15-skyfolio-word-markdown.md` |
| 编译、自检、CI、截图、测速、试 MCP；写代码的规矩 | `docs/development.md` |
| 打包、签名、公证；Apple 开发者账号；发布渠道 | `docs/release.md` |
| MCP 的长期约束 | `docs/architecture/mcp.md` |
| 真机检查清单，每个里程碑一份 | `docs/testing/` |

新写的文档：方案和拍板放 `docs/plans/`，长期约束放 `docs/architecture/`，真机清单放 `docs/testing/`；
开发、发布的操作细节补进上面那两份。
