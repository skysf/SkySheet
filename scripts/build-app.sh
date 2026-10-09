#!/usr/bin/env bash
# SkySheet 打包脚本（只需要命令行工具，不用 Xcode）。照 SrtFlow 的 build-app.sh 改（设计第十一节）。
#
# 用法：
#   VERSION=0.1.0 scripts/build-app.sh   # 正式发版：显式指定版本号
#   scripts/build-app.sh                 # 开发版：版本号取最近的 git tag
#
# 产物：
#   dist/SkySheet.app
#   dist/SkySheet-<VERSION>-arm64.dmg
#
# 注意：紧跟中文的变量一律写成 ${VAR}（bash 会把多字节字符的首字节算进裸变量名里，配上 set -u 当场挂掉）。
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME=SkySheet
DIST=dist

# 版本号不写死默认值：不传 VERSION 就取最近的 tag，HEAD 领先 tag 时明确警告（SrtFlow 踩过写死默认值的坑）。
if [ -z "${VERSION:-}" ]; then
  VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
  if [ -z "${VERSION}" ]; then
    echo "✗ 未传 VERSION，也取不到 git tag。请显式指定：VERSION=x.y.z $0" >&2
    exit 1
  fi
  AHEAD="$(git rev-list --count "v${VERSION}..HEAD" 2>/dev/null || echo 0)"
  if [ "${AHEAD}" -gt 0 ]; then
    echo "⚠️  未传 VERSION，回退到最近的 tag v${VERSION}，但 HEAD 已领先 ${AHEAD} 个提交。"
    echo "    这是开发版产物；正式发版请显式指定：VERSION=x.y.z $0"
  fi
fi

# 一律 --arch arm64：这台 M1 的终端跑在 Rosetta 下，不带就编成 x86_64（CLAUDE.md）。
echo "==> swift build -c release（arm64）"
swift build -c release --arch arm64 --product "${APP_NAME}"
# Claude Code 启动的 MCP 小程序，放进 Contents/Helpers（设计第三节、9.1 节）。
swift build -c release --arch arm64 --product skysheet-mcp
BUILD_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

APP="${DIST}/${APP_NAME}.app"
echo "==> 组装 ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BUILD_DIR}/${APP_NAME}" "${APP}/Contents/MacOS/${APP_NAME}"
strip -xS "${APP}/Contents/MacOS/${APP_NAME}" 2>/dev/null || true

echo "==> 内置 skysheet-mcp"
mkdir -p "${APP}/Contents/Helpers"
cp "${BUILD_DIR}/skysheet-mcp" "${APP}/Contents/Helpers/skysheet-mcp"
strip -xS "${APP}/Contents/Helpers/skysheet-mcp" 2>/dev/null || true
chmod +x "${APP}/Contents/Helpers/skysheet-mcp"

# SwiftPM 的资源包（以后加中文翻译的 .lproj 会在这里）：内容铺进 Contents/Resources，Bundle.main 才找得到。
RESOURCES="${BUILD_DIR}/${APP_NAME}_${APP_NAME}.bundle"
if [ -d "${RESOURCES}/Contents/Resources" ]; then
  ditto "${RESOURCES}/Contents/Resources" "${APP}/Contents/Resources"
elif [ -d "${RESOURCES}" ]; then
  ditto "${RESOURCES}" "${APP}/Contents/Resources"
fi
rm -f "${APP}/Contents/Resources/Info.plist"

cp packaging/Info.plist "${APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${APP}/Contents/Info.plist"

echo "==> 生成图标"
ICON_WORK="$(mktemp -d)"
swift scripts/make-icon.swift "${ICON_WORK}/${APP_NAME}.iconset" >/dev/null
iconutil -c icns "${ICON_WORK}/${APP_NAME}.iconset" -o "${APP}/Contents/Resources/${APP_NAME}.icns"
rm -rf "${ICON_WORK}"

# 签名只经 sign-app.sh 一处（设计第十一节）。
echo "==> codesign"
scripts/signing/sign-app.sh "${APP}"

echo "==> 生成 DMG"
DMG_ROOT="${DIST}/dmg-root"
rm -rf "${DMG_ROOT}"
mkdir -p "${DMG_ROOT}"
cp -R "${APP}" "${DMG_ROOT}/"
ln -s /Applications "${DMG_ROOT}/Applications"

# 没有 Apple 公证（设计第 4 条）：从网上或 AirDrop 拿到的 DMG，第一次打开会被 macOS 拦下，要去系统设置里放行一次。
cat > "${DMG_ROOT}/首次打开必读 - Read Me First.txt" <<'READMEEOF'
SkySheet — 首次打开必读 / Read Me First
=======================================

【中文】

1. 把 SkySheet.app 拖到左边的「应用程序」文件夹，从那里打开（别直接在这个磁盘映像里双击）。

2. 双击 SkySheet。这个 App 没有做 Apple 公证（自用工具），第一次打开会被 macOS 拦下，
   提示「无法打开」。点「完成」/「好」。

3. 打开「系统设置」→「隐私与安全性」，往下翻到「安全性」那一段，会看到一行关于 SkySheet
   被阻止的提示，点右边的「仍要打开」，再输入密码或用触控 ID 确认。

4. 回到「应用程序」里再双击 SkySheet，这次就正常打开了。以上只需要做一次。

用 SkySheet 打开表格：在访达里右键 xlsx / csv 文件 →「打开方式」→ SkySheet；或者先打开 SkySheet，
在「打开」面板里选文件。改完按 ⌘S 保存（第一次覆盖原文件之前会先备份）。
连接 Claude Code：SkySheet 菜单 →「设置…」（⌘,）→ Connect。

运行要求：Apple 芯片（M 系列）Mac，macOS 15 Sequoia 或更新版本。


【English】

1. Drag SkySheet.app into the Applications folder and open it from there, not from this disk image.

2. Double-click SkySheet. The app is not notarised by Apple (it is a personal tool), so macOS blocks
   the first launch and says it cannot be opened. Dismiss that dialog.

3. Open System Settings → Privacy & Security, scroll down to Security, and click "Open Anyway" next to
   the line about SkySheet. Confirm with your password or Touch ID.

4. Double-click SkySheet again. It opens normally from now on.

To open a spreadsheet: right-click an .xlsx or .csv file in Finder → Open With → SkySheet, or start
SkySheet and pick a file. Press Cmd+S to save (SkySheet backs up the original before it first
overwrites a file). To connect Claude Code: SkySheet menu → Settings… (Cmd+,) → Connect.

Requirements: an Apple silicon (M-series) Mac running macOS 15 Sequoia or later.
READMEEOF

DMG="${DIST}/${APP_NAME}-${VERSION}-arm64.dmg"
rm -f "${DMG}"
hdiutil create -volname "${APP_NAME}" -srcfolder "${DMG_ROOT}" -ov -format UDZO "${DMG}" >/dev/null
rm -rf "${DMG_ROOT}"

echo
echo "完成："
du -sh "${APP}" "${DMG}"
