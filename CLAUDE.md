# SkySheet

给 AI 用的轻量 macOS 表格（xlsx / csv）。Claude Code 通过 MCP（`skysheet`）读表、计算，把结果写进新 sheet；
原始数据永远不动。每条决定和理由都在设计文档：`docs/plans/2026-10-08-skysheet-design.md`（下称「设计」）。

## 现在在哪

- M0 完成（仓库、样例、设计），下一步 M1 核心库。里程碑见设计第十三节；每完成一个就改这一行。

## 常用命令

- 编译：`swift build --arch arm64`。这台 M1 的终端跑在 Rosetta 下，不带 `--arch arm64` 会编成 x86_64。
- 自检：`scripts/check-all.sh`（M1 起）。本机没有 XCTest 和 Swift Testing，自检是 `SkySheetChecks` 可执行程序。
- 打包：`VERSION=x.y.z scripts/build-app.sh`（M2 起）。

## 硬规矩

1. `SampleData/` 是作者的真实财务数据：永远不进仓库，也不进 issue、PR、提交说明；测试只用 `Fixtures/`。
2. 原始 sheet 对 AI 只读（设计第 12 条）；保存的六道保险（设计第十节）任何改动都不许绕开。
3. 不认识的东西原样保留：xlsx 里读不懂的部件和元素、公式原文、文件里的缓存值，一律不改、不丢。
4. 零第三方依赖（设计第 7 条）。
5. 签名只经 `scripts/signing/sign-app.sh`。永远不重建「Skylu Signing」证书；私钥在 `~/.config/skylu/signing/`，
   这台机器上没有就停下来问作者。
6. MCP：小程序的 stdout 只写 MCP 消息；工具清单只有一份（`SkySheetMCPKit`）；给模型看的文字只用英文，总说明不超过
   2,048 个字符。
7. main 禁止直推：开分支、提 PR，CI 绿了再合。

## 写代码

- 按职责拆文件，一个文件大约 500 行就考虑拆；多用泛型和共用内核（如设计 5.2 节的函数族、`SparseGrid<Value>`），
  不复制第二份。
- 界面文字只用英文，一律走 String Catalog（设计第 22 条：先做英文版，中文以后补翻译）。
- 注释和文档用中文，写「为什么」；和作者沟通用中文。
- 参考实现：SrtFlow（本机 `../srt_vtt/app_files`，或 `github.com/skysf/SrtFlow`）。签名、MCP 三段结构、自检程序的
  写法从那里搬，按设计删减。
- 文档：`docs/plans/` 放方案和拍板，`docs/architecture/` 放长期约束（随模块落地补），`docs/testing/` 放真机清单。
