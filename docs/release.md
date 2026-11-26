# 发布：打包、签名、公证和 Apple 账号

从 AGENTS.md 分出来的操作细节，AGENTS.md 的「文档目录」指到这里。签名的硬规矩见 AGENTS.md 第 5 条：
只经 `scripts/signing/` 的脚本签名、公证，只在本机做，私钥和凭据不进 CI、不进仓库，证书永远不重建。

## 打包

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

## 发布渠道和用哪把证书（作者 2026-11-26 定）

- **Mac 版，商店外**（DMG，先做这个，好发给别人）：Developer ID 签名并公证。本机自用的包也用它，免得换来换去，
  系统给过的文件夹权限又要重给。
- **App Store**：iPhone、iPad 上 App Store；Mac 等沙盒改造后再上。上商店用 Apple Distribution 证书和 App Store 描述文件，
  传到 App Store Connect 审核。Developer ID 不能用来上商店，商店的包也不用公证。
- 不再用自签名的「Skylu Signing」发版；新方案第 13 条「先不公证」作废。

Mac 为什么先走商店外：Mac App Store 要求 App Sandbox。AI 按路径打开文件、MCP 的 socket、连接 Claude Code 时改它的配置，
在沙盒里都得重做（记在 `TODO.md`「App Store 和真机」）。

## 商店外的 Mac 版（2026-11-26 做好，PR #26）

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

## 账号和凭据的现状

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
