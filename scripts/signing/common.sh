# 发布签名的公共部分（被 create-identity.sh、sign-app.sh source，自己不单独跑）：
# 签名身份放在哪、叫什么、仓库里钉着哪一把，以及签名那几秒把专用钥匙串挂上搜索列表、签完原样放回。
# 照搬 SrtFlow 的 scripts/signing/（那边踩过的坑都在注释里），只换了名字和位置（设计第 4 条、第十一节）。
#
# 为什么要有一把固定的签名身份：macOS 的系统权限（读「下载」「文稿」「桌面」里的文件、钥匙串）按签名记账，
# ad-hoc 签名换一个版本就是「另一个 App」，每次升级都要重新给。
#
# 调用方先 cd 到仓库根目录再 source（SIGNING_PIN_FILE 是相对路径）。

# 仓库外：私钥不进仓库，换机器时把整个目录拷过去。作者所有个人工具共用这一把（bundle id 不同，权限各算各的）。
SIGNING_DIR="${SKYLU_SIGNING_DIR:-${HOME}/.config/skylu/signing}"
SIGNING_KEYCHAIN="${SIGNING_DIR}/skylu-signing.keychain-db"
SIGNING_PASSWORD_FILE="${SIGNING_DIR}/keychain-password"
SIGNING_IDENTITY_NAME="Skylu Signing"
# 发布用的那把证书的 SHA-1。换证书 = 用户给过的系统权限再作废一次，所以钉在仓库里、改它要显式改这个文件。
SIGNING_PIN_FILE="packaging/signing-identity.sha1"

signing_identity_present() {
  [ -f "${SIGNING_KEYCHAIN}" ] && [ -f "${SIGNING_PASSWORD_FILE}" ]
}

# 专用钥匙串里那把证书的 SHA-1（小写十六进制）；找不到输出空。
# 取第一行用 awk 不用 head：pipefail 下 head 提前退出会让上游吃 SIGPIPE、整条管道判失败。
signing_identity_sha1() {
  { security find-certificate -c "${SIGNING_IDENTITY_NAME}" -Z "${SIGNING_KEYCHAIN}" 2>/dev/null || true; } \
    | awk '/^SHA-1 hash: / && !seen++ { print tolower($3) }'
}

# 仓库钉着的 SHA-1（小写）；文件不在或没有内容输出空。
signing_pinned_sha1() {
  if [ -f "${SIGNING_PIN_FILE}" ]; then
    { grep -v '^#' "${SIGNING_PIN_FILE}" || true; } | tr -d '[:space:]' | tr 'A-F' 'a-f'
  fi
}

# codesign 只在搜索列表里的钥匙串中找签名身份：`--keychain` 只是在列表里挑，钥匙串不在列表里就报
# 「no identity found」（SrtFlow 2026-10-03 实测）。所以签名那几秒挂上去、签完原样放回。不长期挂着：上了锁的钥匙串
# 留在列表里，别的 App 找证书时会弹框要它的密码。
SIGNING_SAVED_SEARCH_LIST=()

signing_keychain_attach() {
  local keychain_real line
  keychain_real="$(cd "$(dirname "${SIGNING_KEYCHAIN}")" && pwd -P)/$(basename "${SIGNING_KEYCHAIN}")"
  SIGNING_SAVED_SEARCH_LIST=()
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line#\"}"
    line="${line%\"}"
    # 上一次被强杀没来得及放回的话，列表里还挂着它：记的时候就去掉，放回时顺手摘干净。
    if [ -n "${line}" ] && [ "${line}" != "${keychain_real}" ]; then
      SIGNING_SAVED_SEARCH_LIST+=("${line}")
    fi
  done < <(security list-keychains -d user)
  if [ "${#SIGNING_SAVED_SEARCH_LIST[@]}" -eq 0 ]; then
    # 空列表放回去 = 连登录钥匙串都摘掉了，宁可不签。
    echo "✗ 读不到钥匙串搜索列表（security list-keychains -d user 没输出），不动它" >&2
    return 1
  fi
  security unlock-keychain -p "$(cat "${SIGNING_PASSWORD_FILE}")" "${SIGNING_KEYCHAIN}"
  security list-keychains -d user -s "${SIGNING_SAVED_SEARCH_LIST[@]}" "${keychain_real}"
}

# 放回原来的搜索列表、把专用钥匙串锁上。没挂过也能调、调几次都一样：调用方把它写进自己的 EXIT trap
# （trap 只有一个，这里不替调用方设，免得把调用方自己的清理冲掉）。
signing_keychain_detach() {
  if [ "${#SIGNING_SAVED_SEARCH_LIST[@]}" -gt 0 ]; then
    security list-keychains -d user -s "${SIGNING_SAVED_SEARCH_LIST[@]}"
    SIGNING_SAVED_SEARCH_LIST=()
  fi
  security lock-keychain "${SIGNING_KEYCHAIN}" 2>/dev/null || true
}
