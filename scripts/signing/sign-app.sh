#!/usr/bin/env bash
# 给组装好的 SkyFolio.app 或做好的 DMG 签名（build-app.sh 只经这一处签；设计第十一节、AGENTS.md 硬规矩第 5 条）。
#
# 用仓库钉着的 Developer ID 证书签，开强化运行时（--options runtime）、带安全时间戳（--timestamp）：这两样是公证的前提。
# App 先签 Contents/Helpers 里的可执行文件（M4 起有 skyfolio-mcp）、再签外层：顺序反了外层签名立即失效。
# 签完核对 designated requirement 认的是「Apple 签发 + 我们的 Team ID」：系统给过的权限跟着它走，换版本不作废。
#
# 钥匙串里没有钉着的那把（比如别人从源码编）：退回 ad-hoc 并警告。ad-hoc 的每个新版本在系统里都算「另一个 App」，
# 权限要重新给，也公证不了，不能拿去发给别人。
#
# 第一次用这把私钥签名，macOS 会弹钥匙串授权窗口，要作者输入登录密码、点「始终允许」；没人点，codesign 就一直等着。
#
# 用法：scripts/signing/sign-app.sh <App 或 DMG 路径>
set -euo pipefail
if [ "$#" -ne 1 ] || [ ! -e "$1" ]; then
  echo "用法：scripts/signing/sign-app.sh <App 或 DMG 路径>" >&2
  exit 1
fi
TARGET="$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"
cd "$(dirname "$0")/../.."
source scripts/signing/common.sh

SHA1="$(signing_identity_sha1)"
if [ -n "${SHA1}" ]; then
  echo "   签名身份：Developer ID（Team ${SIGNING_TEAM_ID}，SHA-1 ${SHA1}）"
  IDENTITY=(--sign "${SHA1}" --timestamp)
else
  echo "⚠️  钥匙串里没有仓库钉着的 Developer ID 证书（${SIGNING_PIN_FILE}），退回 ad-hoc 签名。"
  echo "    ad-hoc 的每个新版本在系统里都算「另一个 App」，给过的权限要重新给；也公证不了，别拿去发给别人。"
  IDENTITY=(--sign -)
fi

if [ -d "${TARGET}" ]; then
  # 嵌套的先签、外层最后签。
  if [ -d "${TARGET}/Contents/Helpers" ]; then
    while IFS= read -r helper; do
      codesign --force --options runtime "${IDENTITY[@]}" "${helper}"
    done < <(find "${TARGET}/Contents/Helpers" -type f -perm -u+x | sort)
  fi
  codesign --force --options runtime "${IDENTITY[@]}" "${TARGET}"
  codesign --verify --deep --strict "${TARGET}"
else
  # DMG 只签外壳：里面的 App 已经签好了。
  codesign --force "${IDENTITY[@]}" "${TARGET}"
  codesign --verify "${TARGET}"
fi

if [ -n "${SHA1}" ]; then
  REQUIREMENT="$(codesign -d -r- "${TARGET}" 2>&1 || true)"
  if ! grep -F "anchor apple generic" <<<"${REQUIREMENT}" >/dev/null \
    || ! grep -E "certificate leaf\[subject\.OU\] = \"?${SIGNING_TEAM_ID}\"?" <<<"${REQUIREMENT}" >/dev/null; then
    echo "✗ 签完的 designated requirement 不是「Apple 签发 + Team ${SIGNING_TEAM_ID}」（系统权限会跟着版本作废）：" >&2
    echo "${REQUIREMENT}" >&2
    exit 1
  fi
fi
echo "   签名校验通过"
