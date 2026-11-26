# SkyFolio

所有 AI（Claude、Codex 或别的）共用这一份说明，只维护这一份。CLAUDE.md 只有一句话，把这份引进去；改规矩、改现状都改这里。

给 AI 用的轻量 macOS 表格（xlsx / csv）。Claude Code 通过 MCP（`skyfolio`）读表、计算，把结果写进新 sheet；
原始数据永远不动。每条决定和理由都在设计文档：`docs/plans/2026-10-08-skysheet-design.md`（下称「设计」）。
2026-11-15、11-16 定的计划（同一个 App 还开 Word 和 Markdown、改名 SkyFolio、以后给别人用）在
`docs/plans/2026-11-15-skyfolio-word-markdown.md`（下称「新方案」），按设计第十三节的里程碑一步步做；还没做的别当成已经有了。

## 现在在哪

- M4 完成（MCP v0.3.0，第一个真正可用的版本；v0.3.1 修了连接时整份重排 settings.json），M5 打磨中。里程碑见设计第十三节；每完成一个就改这一行。
- 作者选择朱红文档袋图标，目标是日后在 App Store 分发 Mac、iPad 和 iPhone 版。三端图标取同一母图，配色在 `SkyFolioTheme`。iPhone 和 iPad 共用 `Mobile/SkyFolio.xcodeproj` 里的应用目标。CI 用 `scripts/check-ios.sh` 构建并运行模拟器，本机只需命令行工具。
- 三端共用按操作自动保存和本机历史。写回前先验证、存历史、检查外部改动并备份。重开文档后仍可恢复某一步。Mac 上 AI 在获准工作表的改动默认写回，可整轮撤销。
- 本机装的是 Mac 版 SkyFolio 0.3.11（2026-11-26，PR #24），正式标识为 `ai.skylu.skyfolio`。这一版起 MCP 的 `save_copy` 传 `replace=true` 可以覆盖已有文件，装好后用 MCP 端到端验收过。2026-11-26 同一份包改用 Developer ID 重签、公证后重装，`spctl` 评估 accepted。Codex 通过 `skyfolio-mcp` 连接。仓库改名另行处理。
- **发布渠道**（作者 2026-11-26 定）：Mac 版先在商店外发 DMG，用 Developer ID 签名并公证；iPhone、iPad 上 App Store，Mac 等沙盒改造后也上，上商店用 Apple Distribution 证书。商店外这一路已经做好（PR #26），App Store 还没做，要做的事在 `TODO.md`「App Store 和真机」。
- **所有没做完的事只记在仓库根目录的 `TODO.md`**（作者 2026-11-26 定：待办只维护这一份，别处不另列）。
  - 开工前先读一遍。
  - 第一次回复作者时，用两三句话提醒他还剩什么没做。
  - 做完一项就从那里删掉；新发现、暂时不修的问题也记到那里。

## 常用命令

- **这台电脑资源有限**（16 GB 的 M1，作者同时还在跑别的项目）：
  - **默认本机不编译、不测试**，全放 CI。
  - 本机明显空闲时（`memory_pressure` 空闲 ≥ 30%，且 1 分钟负载 ≤ 4）可以本机编，一律 `nice -n 19`。
  - GitHub 免费账号同一时间最多 5 台 macOS，所有项目共用，SkyCut 的 CI 常常占满。SkySheet 优先级最低，排队就等，不去动别的项目的 CI。
- 编译：`swift build --arch arm64`。这台 M1 的终端跑在 Rosetta 下，不带 `--arch arm64` 会编成 x86_64。
- 自检：`scripts/check-all.sh`（本机和 CI 跑同一个，耗时随合成表负载与机器变化）。本机没有 XCTest 和 Swift Testing，自检是 `SkySheetChecks`
  可执行程序：新功能就在 `Sources/SkySheetChecks/` 里加一个 `*Checks.swift`，再在 `main.swift` 里调用。
  CI 把它拆成两台 macOS 并行跑：`scripts/check-all.sh core`（编译、SkySheetChecks、SampleData 守卫）和
  `scripts/check-all.sh ui`（UI 自检）。两台还分别跑一个移动端配置，覆盖 iPadOS 26.5 和 iOS 18.6。汇总的 `check-all` 两边都 success 才绿。本机照旧不带参数跑全部 Mac 自检。
  移动端失败的用例会在同一台模拟器上自动再跑一次，重跑才过的在 PR 上标黄色警告。模拟器的「文件」服务自己交不出所选文件时
  （系统日志里 FP -1005），选文件那条只记警告、不判失败；怎么认定写在 `scripts/check-ios.sh`。
  后台 UI 自检用 `nice -n 10 scripts/check-ui.sh [editing|copy-limit|theme|format|appearance|locale|drawing|ai]`，不给套件就全跑。
  在 `Sources/SkySheetChecks/UI/` 加断言，再到唯一套件入口 `UI/main.swift` 注册；SPM 换入口编译同一份 App 源文件，
  不启动文档恢复或 MCP、不接系统剪贴板。
- 打包：`VERSION=x.y.z scripts/build-app.sh`，产物在 `dist/`：用 Developer ID 签名，App 和 DMG 都公证、钉上票据（要联网，
  各要几分钟；`NOTARIZE=0` 跳过，只给自己试的包用）。
  本机不编的做法（`.github/workflows/build-app.yml`，只能手动触发）：
  1. 在要打包的分支运行 `gh workflow run build-app.yml --ref <分支> -f version=x.y.z`；
  2. 跑完 `gh run download <run id> -n SkyFolio-x.y.z-arm64-adhoc -D 新目录` 拿到 zip，`ditto -x -k <zip> 新目录` 解开；
  3. 本机 `scripts/signing/sign-app.sh <解出的 SkyFolio.app>` 签名，再 `scripts/signing/notarize.sh <同一个 App>` 公证、钉票据。
     CI 的包用 ad-hoc 签名，证书、私钥和公证凭据都只在本机；
  4. 核对 `codesign -dvv <App>` 的 Authority 是 `Developer ID Application: TIANYU LU (26TVX3S9FR)`，
     `spctl --assess --type execute -vv <App>` 是 accepted、source=Notarized Developer ID（`notarize.sh` 最后会打出来）。
  CI 不传 DMG（里面是 ad-hoc 签的包，不能给人）；发版的 DMG 照旧本机 `build-app.sh` 出，签名和公证都在本机做（设计第十一节）。
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
- 试 MCP：打包后用 JSON-RPC 直接跟 `dist/SkyFolio.app/Contents/Helpers/skyfolio-mcp` 说话；要和真的 Claude Code 试，用
  `claude -p "…" --mcp-config <临时 json> --strict-mcp-config --allowedTools mcp__skyfolio`，不动用户自己的配置
  （`docs/architecture/mcp.md` 第五节）。
- 真机检查清单：`docs/testing/`，每个里程碑一份。

## 硬规矩

1. `SampleData/` 是作者的真实财务数据：永远不进仓库，也不进 issue、PR、提交说明；测试只用 `Fixtures/`。
2. 原始 sheet 对 AI 只读（设计第 12 条）；保存的六道保险（设计第十节）任何改动都不许绕开。
3. 不认识的东西原样保留：xlsx 里读不懂的部件和元素、公式原文、文件里的缓存值，一律不改、不丢。
4. 不通过包管理器引第三方库（`Package.swift` 没有 `dependencies`）。别人的开源代码只能按设计第 7 条复制进 `ThirdParty/<项目名>/`：
   许可证和 AGPL-3.0 兼容，带原许可证和 `SOURCE.md`（出处、提交、改了什么），从此当自己的代码维护。
5. 签名只经 `scripts/signing/` 里的脚本（`sign-app.sh` 签名，`notarize.sh` 公证）。证书按发布渠道选（作者 2026-11-26 定，见文末）：
   商店外的 Mac 版用 Developer ID 并公证，上 App Store 用 Apple Distribution。签名和公证只在本机做，私钥和凭据不进 CI、
   不进仓库。证书永远不重建（包括旧的「Skylu Signing」），这台机器上没有就停下来问作者。
6. MCP：小程序的 stdout 只写 MCP 消息；工具清单只有一份（`SkySheetMCPKit`）；给模型看的文字只用英文，总说明不超过
   2,048 个字符。
7. main 禁止直推：开分支、提 PR，CI 绿了再合。

## 写代码

- 按职责拆文件，一个文件大约 500 行就考虑拆；多用泛型和共用内核（如设计 5.2 节的函数族、`SparseGrid<Value>`），
  不复制第二份。
- 界面文字只用英文，一律写成 `String(localized:)`（设计第 22 条：先做英文版，中文以后补翻译；本机没有 xcstringstool，
  String Catalog 等加中文时再生成）。
- 注释和文档用中文，写「为什么」；和作者沟通用中文。
- 参考实现：SrtFlow（本机 `../srt_vtt/app_files`，或 `github.com/skysf/SrtFlow`）。签名、MCP 三段结构、自检程序的
  写法从那里搬，按设计删减。
- 文档：`docs/plans/` 放方案和拍板，`docs/architecture/` 放长期约束（随模块落地补：`mcp.md`），`docs/testing/` 放真机清单；待办只记在根目录的 `TODO.md`。

## Apple 开发者账号和签名

发布渠道和用哪把证书（作者 2026-11-26 定）：
- **Mac 版，商店外**（DMG，先做这个，好发给别人）：Developer ID 签名并公证。本机自用的包也用它，免得换来换去，
  系统给过的文件夹权限又要重给。
- **App Store**：iPhone、iPad 上 App Store；Mac 等沙盒改造后再上。上商店用 Apple Distribution 证书和 App Store 描述文件，
  传到 App Store Connect 审核。Developer ID 不能用来上商店，商店的包也不用公证。
- 不再用自签名的「Skylu Signing」发版；新方案第 13 条「先不公证」作废。

Mac 为什么先走商店外：Mac App Store 要求 App Sandbox。AI 按路径打开文件、MCP 的 socket、连接 Claude Code 时改它的配置，
在沙盒里都得重做（记在 `TODO.md`「App Store 和真机」）。

商店外的 Mac 版（2026-11-26 做好，PR #26）：
- `sign-app.sh` 用仓库钉着的 Developer ID 证书（`packaging/signing-identity.sha1`）签，开强化运行时、带时间戳，
  签完核对认的是「Apple 签发 + Team ID」。钥匙串里没有这把证书（比如别人从源码编）就退回 ad-hoc 并警告。
- `notarize.sh` 用 `notarytool` 的 `skylu-notary` 提交公证，通过后 `stapler` 钉票据、`spctl` 评估。App 交 zip，DMG 直接交。
  一次二三十秒到几分钟。
- 2026-11-26 实测：0.3.11 的 App 和 DMG 都公证通过，`spctl` 都是 accepted、source=Notarized Developer ID。
  开了强化运行时的 App 通过 MCP 拉起、回 `get_status` 都正常，没有加任何 entitlements。
- 从「Skylu Signing」换过来的第一版，系统给过的文件夹权限（「文稿」「下载」等）要再给一次：权限按签名记，签名换了。
  以后同一个 Team 换版本、续证书都不用再给。
- 证书 2027-12-25 到期。续了新证书，改 `packaging/signing-identity.sha1`。

App Store 那一路还没做完的，记在 `TODO.md`「App Store 和真机」。

现状：
- **账号**：Apple Developer Program 已续费，个人账号。Team ID `26TVX3S9FR`，团队名 TIANYU LU。
- **签名身份**：`Developer ID Application: TIANYU LU (26TVX3S9FR)`，在 login 钥匙串里。
  - SHA-1 `1EC5EDA20BE8A7584E1744525669A3AFE69F8841`，2027-12-25 到期。
  - `security find-identity -v -p codesigning` 显示 1 valid（2026-11-25 核对过）。
- **公证凭据**：钥匙串里的 notarytool profile，2026-11-26 用 `notarytool history` 核对过，两份都能用。
  - `skylu-notary`：团队 API Key，默认用它。
  - `notary-26TVX3S9FR`：App 专用密码，作者别的项目建的，备用。改或重置 Apple ID 密码时它会作废。
- **本机**：没有 Xcode，只有命令行工具（`notarytool`、`stapler` 都有）。证书链需要的 Developer ID G2 中间证书已经手动装好。
- **钥匙串授权**：2026-11-26 在这台机器上签名没有弹窗，私钥已经允许 `codesign` 用。
  换机器、重新导入证书以后，第一次签会弹钥匙串授权窗口，要作者输入登录密码、点「始终允许」：
  - 签之前先告诉作者；
  - 窗口没人点，codesign 就一直停在那里等。
