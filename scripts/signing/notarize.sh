#!/usr/bin/env bash
# 把 Developer ID 签好的 App 或 DMG 交给 Apple 公证，通过以后把票据钉上（stapler），再让 Gatekeeper 评估一遍。
# 公证过的包从网上下载后打开，macOS 只提示一句「从互联网下载」，不再拦（docs/release.md）。
#
# 凭据是 notarytool 存在钥匙串里的 profile（common.sh 的 NOTARY_PROFILE，默认 skylu-notary）。只在本机跑：
# 凭据不进 CI、不进仓库。要联网，一次通常几分钟。
#
# 用法：scripts/signing/notarize.sh <App 或 DMG 路径>
set -euo pipefail
if [ "$#" -ne 1 ] || [ ! -e "$1" ]; then
  echo "用法：scripts/signing/notarize.sh <App 或 DMG 路径>" >&2
  exit 1
fi
TARGET="$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"
cd "$(dirname "$0")/../.."
source scripts/signing/common.sh

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
if [ -d "${TARGET}" ]; then
  # App 是个目录，交给公证的是它的 zip；票据钉在 App 本身上。
  SUBMIT="${WORK}/$(basename "${TARGET}" .app).zip"
  ditto -c -k --keepParent "${TARGET}" "${SUBMIT}"
else
  SUBMIT="${TARGET}"
fi

echo "==> 公证 $(basename "${TARGET}")（profile ${NOTARY_PROFILE}）"
RESULT="${WORK}/result.json"
xcrun notarytool submit "${SUBMIT}" --keychain-profile "${NOTARY_PROFILE}" --wait --output-format json >"${RESULT}"
STATUS="$(plutil -extract status raw -o - "${RESULT}" 2>/dev/null || true)"
ID="$(plutil -extract id raw -o - "${RESULT}" 2>/dev/null || true)"
if [ "${STATUS}" != "Accepted" ]; then
  echo "✗ 公证没通过（${STATUS:-没有结果}，提交 ${ID:-?}）。Apple 给的说明：" >&2
  if [ -n "${ID}" ]; then
    xcrun notarytool log "${ID}" --keychain-profile "${NOTARY_PROFILE}" >&2 || true
  fi
  exit 1
fi
echo "   公证通过（提交 ${ID}）"

xcrun stapler staple "${TARGET}"
xcrun stapler validate "${TARGET}"
if [ -d "${TARGET}" ]; then
  spctl --assess --type execute -vv "${TARGET}"
else
  spctl --assess --type open --context context:primary-signature -vv "${TARGET}"
fi
echo "   票据已钉上，Gatekeeper 评估通过"
