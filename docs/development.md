# 开发：编译、自检和 CI

从 AGENTS.md 分出来的操作细节，AGENTS.md 的「文档目录」指到这里。硬规矩以 AGENTS.md 为准。

## 本机和 CI 怎么分工（作者 2026-11-26 定）

- **默认在本机编译，只跑和这次改动相关的小测试；重的测试放 CI。**
  - 本机：`swift build --arch arm64`；改到哪块就跑哪块的自检，比如改了 AI 跑 `nice -n 10 scripts/check-ui.sh ai`；改了表格画法截一张图看（下面「看显示效果」）。
  - CI：完整的 `scripts/check-all.sh`（拆成 core、ui 两台）、全部 UI 自检套件、iPhone 和 iPad 模拟器。每个 PR 都会跑，本机不用重复。
  - 测速、标准截图集也重，改了画法才跑。在本机跑要挑机器空的时候，数字只和同一台机器上的比。
- 这台电脑是 16 GB 的 M1，作者同时还在跑别的项目：本机编译、测试都加 `nice -n 10`，不跟作者手上的活抢；内存明显吃紧时先停下，改放 CI。
- 测试只在后台跑：不弹窗、不抢焦点、不模拟键鼠。
- GitHub 免费账号同一时间最多 5 台 macOS，所有项目共用，SkyCut 的 CI 常常占满。SkySheet 优先级最低，排队就等，不去动别的项目的 CI。

## 编译和自检

- 编译：`swift build --arch arm64`。这台 M1 的终端跑在 Rosetta 下，不带 `--arch arm64` 会编成 x86_64。
- 自检：`scripts/check-all.sh`（本机和 CI 跑同一个，耗时随合成表负载与机器变化）。本机没有 XCTest 和 Swift Testing，自检是 `SkySheetChecks`
  可执行程序：新功能就在 `Sources/SkySheetChecks/` 里加一个 `*Checks.swift`，再在 `main.swift` 里调用。
  CI 把它拆成两台 macOS 并行跑：`scripts/check-all.sh core`（编译、SkySheetChecks、SampleData 守卫）和
  `scripts/check-all.sh ui`（UI 自检）。两台还分别跑一个移动端配置，覆盖 iPadOS 26.5 和 iOS 18.6。汇总的 `check-all` 两边都 success 才绿。
  不带参数就是全部 Mac 自检，重，默认交给 CI。
  移动端失败的用例会在同一台模拟器上自动再跑一次，重跑才过的在 PR 上标黄色警告。模拟器的「文件」服务自己交不出所选文件时
  （系统日志里 FP -1005），选文件那条只记警告、不判失败；怎么认定写在 `scripts/check-ios.sh`。
  后台 UI 自检用 `nice -n 10 scripts/check-ui.sh [editing|copy-limit|theme|format|appearance|locale|drawing|ai]`，不给套件就全跑。
  在 `Sources/SkySheetChecks/UI/` 加断言，再到唯一套件入口 `UI/main.swift` 注册；SPM 换入口编译同一份 App 源文件，
  不启动文档恢复或 MCP、不接系统剪贴板。
- 移动端：iPhone 和 iPad 共用 `Mobile/SkyFolio.xcodeproj` 里的应用目标，CI 用 `scripts/check-ios.sh` 构建并跑模拟器；本机只有命令行工具，不跑移动端。
  三端图标取同一张母图（作者选的朱红文档袋），配色在 `SkyFolioTheme`。

## 看效果、测速、看存出来的文件

- 看显示效果：`.build/arm64-apple-macosx/debug/SkySheet --snapshot-input 文件 --snapshot-output 图.png [--select K60] [--zoom 1.5] [--appearance aqua|dark]`，
  把整个窗口画成 PNG（设计 8.2 节）。改了表格的画法就截一张看。截图、测速只写新文件，输出路径已经有东西就拒绝。
- 测速（设计 8.2 节「性能」）：`swift build -c release --arch arm64 --product SkySheet` 以后
  `.build/arm64-apple-macosx/release/SkySheet --benchmark synthetic:data|synthetic:formulas|synthetic:styles|文件.xlsx
  [--benchmark-only …]`，逐帧报主线程 CPU 时间；`--benchmark-only verify` 逐像素核对局部重画，改了画法就跑。
  截图、测速都不弹窗口。`scroll` 默认保持历史行为；长时间循环采样另加 `--benchmark-cycle-scroll`，不能混着比历史数字。
- 标准截图集：`nice -n 10 scripts/capture-ui.sh APP 全新输出目录 [--appearance aqua|dark]`。输入会在输出目录的 `inputs/`
  自动合成，不需手工准备文件；包含纯数据、公式、样式、跨窗格合并、居中溢出和画布边界。只写临时目录，不提交截图或生成的表。
  前后各跑一次后，`nice -n 10 swift scripts/compare-ui.swift 前图目录 后图目录 全新差异目录` 逐像素比较，
  输出像素计数 JSON 和有变化的三栏图（前／后／红色差异）。导航后缩回的截图可用
  `SKYSHEET_UI_NAV_SNAPSHOT=已有临时目录 nice -n 10 scripts/check-ui.sh drawing` 生成。
- 看存出来的文件：`SKYSHEET_CHECK_OUTPUT=文件夹 swift run --arch arm64 --skip-build SkySheetChecks` 把保存自检写出的
  xlsx 留在那个文件夹，可以拿 `qlmanage -t` 或别的软件打开看。

## 试 MCP

- 试 MCP：打包后用 JSON-RPC 直接跟 `dist/SkyFolio.app/Contents/Helpers/skyfolio-mcp` 说话；要和真的 Claude Code 试，用
  `claude -p "…" --mcp-config <临时 json> --strict-mcp-config --allowedTools mcp__skyfolio`，不动用户自己的配置
  （`docs/architecture/mcp.md` 第五节）。

真机检查清单在 `docs/testing/`，每个里程碑一份。

## 写代码

- 按职责拆文件，一个文件大约 500 行就考虑拆；多用泛型和共用内核（如设计 5.2 节的函数族、`SparseGrid<Value>`），
  不复制第二份。
- 界面文字只用英文，一律写成 `String(localized:)`（设计第 22 条：先做英文版，中文以后补翻译；本机没有 xcstringstool，
  String Catalog 等加中文时再生成）。
- 注释和文档用中文，写「为什么」；和作者沟通用中文。
- 参考实现：SrtFlow（本机 `../srt_vtt/app_files`，或 `github.com/skysf/SrtFlow`）。签名、MCP 三段结构、自检程序的
  写法从那里搬，按设计删减。
