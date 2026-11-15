#!/usr/bin/env bash
# 直接链接 debug 的 App 对象来测真实会话和画法，避免为了自检搬动生产模块。main 对象不链接，所以不会启动文档、恢复和 MCP。
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD=.build/arm64-apple-macosx/debug
OBJECTS=()
for target in SkySheet SkySheetCore SkySheetDisplay SkySheetFiles SkySheetMCPKit SkyZip; do
  for object in "${BUILD}/${target}.build/"*.swift.o; do
    [[ "${object}" == */main.swift.o ]] || OBJECTS+=("${object}")
  done
done
swiftc -swift-version 6 -target arm64-apple-macosx15.0 -I "${BUILD}/Modules" \
  Sources/SkySheetChecks/Harness.swift Sources/SkySheetChecks/UI/*.swift \
  "${OBJECTS[@]}" -o "${BUILD}/SkySheetUIChecks"
if [[ $# -gt 0 ]]; then
  exec "${BUILD}/SkySheetUIChecks" "$@"
fi
FAILED=0
# 崩溃入口分进程，负主题编号和格式编号溢出必须分别验证。
for suite in editing copy-limit theme format locale; do
  "${BUILD}/SkySheetUIChecks" "${suite}" || FAILED=1
done
exit "${FAILED}"
