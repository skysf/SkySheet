#!/usr/bin/env bash
# 只编工作簿引擎、文件格式和界面配色。AppKit 窗口、桌面 MCP 小程序都有自己的 Mac 目标。
set -euo pipefail
cd "$(dirname "$0")/.."

for sdk in iphoneos iphonesimulator; do
  triple=arm64-apple-ios18.0
  if [[ "$sdk" == iphonesimulator ]]; then triple+=-simulator; fi
  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
  for target in SkySheetFiles SkySheetDisplay SkyFolioTheme; do
    swift build -j 4 --sdk "$sdk_path" --triple "$triple" --target "$target" \
      --scratch-path "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/SkyFolio-iOS-build/$sdk"
  done
done
