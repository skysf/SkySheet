#!/usr/bin/env bash
# SkyFolio 打包脚本（只需要命令行工具，不用 Xcode）。照 SrtFlow 的 build-app.sh 改（设计第十一节）。
#
# 用法：
#   VERSION=0.1.0 scripts/build-app.sh   # 正式发版：显式指定版本号
#   scripts/build-app.sh                 # 开发版：版本号取最近的 git tag
#
# 产物：
#   dist/SkyFolio.app
#   dist/SkyFolio-<VERSION>-arm64.dmg
#
# 注意：紧跟中文的变量一律写成 ${VAR}（bash 会把多字节字符的首字节算进裸变量名里，配上 set -u 当场挂掉）。
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME=SkyFolio
SWIFT_PRODUCT=SkySheet
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

# 一律 --arch arm64：这台 M1 的终端跑在 Rosetta 下，不带就编成 x86_64（AGENTS.md）。
echo "==> swift build -c release（arm64）"
swift build -c release --arch arm64 --product "${SWIFT_PRODUCT}"
# Claude Code 启动的 MCP 小程序，放进 Contents/Helpers（设计第三节、9.1 节）。
swift build -c release --arch arm64 --product skyfolio-mcp
BUILD_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

APP="${DIST}/${APP_NAME}.app"
echo "==> 组装 ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BUILD_DIR}/${SWIFT_PRODUCT}" "${APP}/Contents/MacOS/${APP_NAME}"
strip -xS "${APP}/Contents/MacOS/${APP_NAME}" 2>/dev/null || true

echo "==> 内置 skyfolio-mcp"
mkdir -p "${APP}/Contents/Helpers"
cp "${BUILD_DIR}/skyfolio-mcp" "${APP}/Contents/Helpers/skyfolio-mcp"
strip -xS "${APP}/Contents/Helpers/skyfolio-mcp" 2>/dev/null || true
chmod +x "${APP}/Contents/Helpers/skyfolio-mcp"

# SwiftPM 的资源包（以后加中文翻译的 .lproj 会在这里）：内容铺进 Contents/Resources，Bundle.main 才找得到。
RESOURCES="${BUILD_DIR}/${SWIFT_PRODUCT}_${SWIFT_PRODUCT}.bundle"
if [ -d "${RESOURCES}/Contents/Resources" ]; then
  ditto "${RESOURCES}/Contents/Resources" "${APP}/Contents/Resources"
elif [ -d "${RESOURCES}" ]; then
  ditto "${RESOURCES}" "${APP}/Contents/Resources"
fi
rm -f "${APP}/Contents/Resources/Info.plist"

cp packaging/Info.plist "${APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${APP}/Contents/Info.plist"
# 打包时间：用户问 AI「SkyFolio 是什么时候的」，get_status 当场答，不用上网找。
/usr/libexec/PlistBuddy -c "Set :SkyFolioBuildDate $(date -u +%Y-%m-%dT%H:%M:%SZ)" "${APP}/Contents/Info.plist"

echo "==> 生成图标"
ICON_WORK="$(mktemp -d)"
swift scripts/make-icon.swift "${ICON_WORK}/${APP_NAME}.iconset" >/dev/null
iconutil -c icns "${ICON_WORK}/${APP_NAME}.iconset" -o "${APP}/Contents/Resources/${APP_NAME}.icns"
rm -rf "${ICON_WORK}"

# 签名只经 sign-app.sh 一处（设计第十一节）。
echo "==> codesign"
scripts/signing/sign-app.sh "${APP}"

# 公证（AGENTS.md「Apple 开发者账号和签名」）：Developer ID 签的包才能公证，公证过的才能发给别人。
# NOTARIZE=0 跳过：离线、只给自己试的包。先公证 App 再装进 DMG：拷出 DMG 的 App 身上带着票据，离线也认。
NOTARIZED=0
if [ "${NOTARIZE:-1}" != "0" ] && codesign -dvv "${APP}" 2>&1 | grep -q '^Authority=Developer ID Application'; then
  scripts/signing/notarize.sh "${APP}"
  NOTARIZED=1
else
  echo "⚠️  没有公证（NOTARIZE=0，或不是 Developer ID 签的）：这个包只能本机用，发给别人会被 macOS 拦下。"
fi

echo "==> 生成 DMG"
DMG_ROOT="${DIST}/dmg-root"
rm -rf "${DMG_ROOT}"
mkdir -p "${DMG_ROOT}"
cp -R "${APP}" "${DMG_ROOT}/"
ln -s /Applications "${DMG_ROOT}/Applications"

# 公证过的包从网上或 AirDrop 拿到，第一次打开 macOS 只问一句「从互联网下载」，点「打开」就行。
cat > "${DMG_ROOT}/首次打开必读 - Read Me First.txt" <<'READMEEOF'
SkyFolio — 首次打开必读 / Read Me First
=======================================

【中文】

1. 把 SkyFolio.app 拖到左边的「应用程序」文件夹，从那里打开（别直接在这个磁盘映像里双击）。

2. 双击 SkyFolio。第一次打开时 macOS 会提示它是从互联网下载的，点「打开」。
   SkyFolio 经过 Apple 公证，以后就直接打开了。

用 SkyFolio 打开表格：在访达里右键 xlsx / csv 文件 →「打开方式」→ SkyFolio；或者先打开 SkyFolio，
在「打开」面板里选文件。每次编辑提交后会自动保存，第一次覆盖之前会备份原件。可以用 File → Version History 恢复到某一步。
连接 Claude Code 或 Claude 桌面版的聊天：SkyFolio 菜单 →「设置…」（⌘,）→ 那一行的 Connect。

运行要求：Apple 芯片（M 系列）Mac，macOS 15 Sequoia 或更新版本。


【English】

1. Drag SkyFolio.app into the Applications folder and open it from there, not from this disk image.

2. Double-click SkyFolio. The first time, macOS says it was downloaded from the internet; click Open.
   SkyFolio is notarized by Apple, so later launches open directly.

To open a spreadsheet: right-click an .xlsx or .csv file in Finder → Open With → SkyFolio, or start
SkyFolio and pick a file. Edits save automatically, with a backup before the first overwrite.
Choose File → Version History to restore an earlier edit. To connect Claude Code or the Claude desktop app's chats, choose SkyFolio menu →
Settings… (Cmd+,) → Connect on that row.

Requirements: an Apple silicon (M-series) Mac running macOS 15 Sequoia or later.
READMEEOF

DMG="${DIST}/${APP_NAME}-${VERSION}-arm64.dmg"
rm -f "${DMG}"
hdiutil create -volname "${APP_NAME}" -srcfolder "${DMG_ROOT}" -ov -format UDZO "${DMG}" >/dev/null
rm -rf "${DMG_ROOT}"

echo "==> 给 DMG 签名、公证"
scripts/signing/sign-app.sh "${DMG}"
if [ "${NOTARIZED}" = "1" ]; then
  scripts/signing/notarize.sh "${DMG}"
fi

echo
echo "完成："
du -sh "${APP}" "${DMG}"
