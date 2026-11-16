#!/usr/bin/env bash
# 全部自检的入口：本机和 CI 跑同一个（设计第十二节）。
# 任何一项红，退出码就不是 0；单项失败不中断，一次跑完看全貌。
#
# 用法：
#   scripts/check-all.sh        # 全部：编译、SkySheetChecks、UI 自检、SampleData 守卫（本机照旧这么用）
#   scripts/check-all.sh core   # 只跑编译、SkySheetChecks、SampleData 守卫
#   scripts/check-all.sh ui     # 只跑 UI 自检（scripts/check-ui.sh 自己编一份，在 .build/ui-checks）
# CI 把 core 和 ui 分到两台机器上并行跑，再由汇总的 check-all 要求两边都过（设计第十一节）。
#
# 注意：这个仓库的 .sh 里有中文提示。紧跟中文的变量一律写成 ${VAR}：bash 展开裸变量名时会把多字节字符的
# 首字节也算进名字里，配上 set -u 当场报 unbound variable（SrtFlow 踩过，docs/bugfixes/2026-08-06-build-version-and-shell-traps.md）。
set -uo pipefail
cd "$(dirname "$0")/.."

# 参数写错就直接失败，不悄悄退回「全部」：CI 上拼错一个字会变成两台机器都跑全套，或者什么都没跑却报绿。
MODE=all
if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != "core" ] && [ "$1" != "ui" ]; }; then
  echo "用法：scripts/check-all.sh [core|ui]" >&2
  exit 2
fi
if [ "$#" -eq 1 ]; then
  MODE="$1"
fi

# 这台 M1 的终端跑在 Rosetta 下，不带 --arch arm64 会编成 x86_64（CLAUDE.md）。CI 的机器本来就是 arm64，带上也一样。
ARCH=(--arch arm64)
FAILED=""

step() {
  local name="$1"
  shift
  echo "==> ${name}"
  if "$@"; then
    echo "    ✓ ${name}"
    return 0
  fi
  echo "    ✗ ${name}"
  FAILED="${FAILED}  - ${name}\n"
  return 1
}

if [ "${MODE}" = "ui" ]; then
  echo "临时：故意让 ui 失败，验证汇总的 check-all 会变红（下一个提交删掉）" >&2
  exit 1
  # check-ui.sh 自己编（scratch path 是 .build/ui-checks），不依赖 core 那份编译。
  step "SkySheet UI checks (offscreen)" scripts/check-ui.sh
else
  # 编译失败就不跑自检：swift run --skip-build 会跑上一次编好的旧程序，给出假绿。
  # 自检程序也不接管道（| tail 之类）：管道的退出码是最后一个命令的，失败会被吞掉。
  if step "编译" swift build -j 4 "${ARCH[@]}"; then
    step "SkySheetChecks" swift run "${ARCH[@]}" --skip-build SkySheetChecks
    if [ "${MODE}" = "all" ]; then
      step "SkySheet UI checks (offscreen)" scripts/check-ui.sh
    fi
  else
    FAILED="${FAILED}  - SkySheetChecks（没跑：编译失败）\n"
  fi

  # 作者的真实表格只在本机（设计第 19 条）。
  step "SampleData 没有进仓库" test -z "$(git ls-files SampleData)"
fi

if [ -n "${FAILED}" ]; then
  printf '\n✗ 没过的检查：\n%b' "${FAILED}" >&2
  exit 1
fi
echo
if [ "${MODE}" = "all" ]; then
  echo "✓ 全部通过"
else
  echo "✓ ${MODE} 这部分全部通过"
fi
