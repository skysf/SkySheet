# 发布签名的公共部分（被 sign-app.sh、notarize.sh source，自己不单独跑）：用哪把证书、仓库钉着哪一把、公证用哪份凭据。
#
# 2026-11-26 起用 Developer ID 签名并公证（作者定，AGENTS.md「Apple 开发者账号和签名」）：这样的包才能发给别人，
# 从网上下载后打开，macOS 不再拦。本机自用的包也用它，免得签名换来换去、系统权限又要重给。
# 以前的自签名「Skylu Signing」不再用来签 SkyFolio；作者别的个人工具还在用那把证书，永远不重建。
#
# 为什么要钉住证书：macOS 的系统权限（读「下载」「文稿」「桌面」里的文件）按签名记账。Developer ID 签的版本，
# designated requirement 是「Apple 签发 + bundle id + Team ID」，同一个团队换版本、换证书都不变；
# 从别的签名换过来的第一版，权限要再给一次（TN3127）。
#
# 调用方先 cd 到仓库根目录再 source（SIGNING_PIN_FILE 是相对路径）。

# 证书和私钥在 login 钥匙串里，不进仓库、不进 CI。按仓库钉着的 SHA-1 找，不按名字：名字可能对上好几把。
SIGNING_TEAM_ID="26TVX3S9FR"
SIGNING_PIN_FILE="packaging/signing-identity.sha1"
# notarytool 存在钥匙串里的凭据（团队 API Key）。备用的另一份见 AGENTS.md。
NOTARY_PROFILE="${SKYFOLIO_NOTARY_PROFILE:-skylu-notary}"

# 仓库钉着的 SHA-1（小写）；文件不在或没有内容输出空。
signing_pinned_sha1() {
  if [ -f "${SIGNING_PIN_FILE}" ]; then
    { grep -v '^#' "${SIGNING_PIN_FILE}" || true; } | tr -d '[:space:]' | tr 'A-F' 'a-f'
  fi
}

# 钥匙串里能签代码、而且就是钉着的那一把：有就输出它的 SHA-1（小写），没有输出空。
# 取第一行用 awk 不用 head：pipefail 下 head 提前退出会让上游吃 SIGPIPE、整条管道判失败。
signing_identity_sha1() {
  local pinned
  pinned="$(signing_pinned_sha1)"
  if [ -n "${pinned}" ]; then
    { security find-identity -v -p codesigning 2>/dev/null || true; } \
      | awk -v want="${pinned}" 'tolower($2) == want && !seen++ { print want }'
  fi
}
