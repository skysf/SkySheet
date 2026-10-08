#!/usr/bin/env bash
# 全部自检的入口：本机和 CI 跑同一个（设计第十二节）。
# 任何一项红，退出码就不是 0；单项失败不中断，一次跑完看全貌。
#
# 用法：scripts/check-all.sh
#
# 注意：这个仓库的 .sh 里有中文提示。紧跟中文的变量一律写成 ${VAR}：bash 展开裸变量名时会把多字节字符的
# 首字节也算进名字里，配上 set -u 当场报 unbound variable（SrtFlow 踩过，docs/bugfixes/2026-08-06-build-version-and-shell-traps.md）。
set -uo pipefail
cd "$(dirname "$0")/.."

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

# 编译失败就不跑自检：swift run --skip-build 会跑上一次编好的旧程序，给出假绿。
# 自检程序也不接管道（| tail 之类）：管道的退出码是最后一个命令的，失败会被吞掉。
if step "编译" swift build "${ARCH[@]}"; then
  step "SkySheetChecks" swift run "${ARCH[@]}" --skip-build SkySheetChecks
else
  FAILED="${FAILED}  - SkySheetChecks（没跑：编译失败）\n"
fi

# 作者的真实表格只在本机（设计第 19 条）。
step "SampleData 没有进仓库" test -z "$(git ls-files SampleData)"

if [ -n "${FAILED}" ]; then
  printf '\n✗ 没过的检查：\n%b' "${FAILED}" >&2
  exit 1
fi
echo
echo "✓ 全部通过"
