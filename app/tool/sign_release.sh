#!/usr/bin/env bash
# =====================================================================
#  ArchoeraMusic 发布产物签名 —— ECDSA/SHA-256 分离签名（<asset>.sig1）。
#
#  key1 由 CI 在受保护 `release` Environment（人工审批）签署；公钥随发布分发。
#  私钥来源（二选一）：
#    - 环境变量 ARCHOERA_WM_KEY1_PEM（CI secret：整个 PEM 内容，推荐）
#    - 文件 ARCHOERA_WM_KEY1_FILE / 默认 ~/.config/archoera/watermark_ec_priv.pem
#  仅 POSIX。
#
#  用法：bash app/tool/sign_release.sh [dist/linux]
# =====================================================================
set -euo pipefail

KEYDIR="${ARCHOERA_WM_KEYDIR:-$HOME/.config/archoera}"
K1="${ARCHOERA_WM_KEY1_FILE:-$KEYDIR/watermark_ec_priv.pem}"
TMP1=""
cleanup() {
  [ -n "$TMP1" ] && rm -f "$TMP1"
  return 0
}
trap cleanup EXIT
if [ -n "${ARCHOERA_WM_KEY1_PEM:-}" ]; then
  TMP1="$(mktemp)"; printf '%s\n' "$ARCHOERA_WM_KEY1_PEM" > "$TMP1"; chmod 600 "$TMP1"; K1="$TMP1"
fi

[ -f "$K1" ] || {
  echo "缺少私钥（设置 ARCHOERA_WM_KEY1_PEM，或放置 $K1）" >&2
  exit 1
}
DIST="${1:-dist/linux}"
[ -d "$DIST" ] || { echo "产物目录不存在: $DIST" >&2; exit 1; }

# 汇总校验和（便于人工核对）
(
  cd "$DIST"
  # shellcheck disable=SC2012
  ls ./*.tar.gz ./*.tar.xz ./*.deb ./*.rpm ./*.AppImage ./*.pkg.tar.zst \
     ./*.zip ./*.exe 2>/dev/null | xargs -r sha256sum > SHA256SUMS || true
)

for f in "$DIST"/*.tar.gz "$DIST"/*.tar.xz "$DIST"/*.deb "$DIST"/*.rpm \
         "$DIST"/*.AppImage "$DIST"/*.pkg.tar.zst "$DIST"/*.zip "$DIST"/*.exe \
         "$DIST"/SHA256SUMS; do
  [ -f "$f" ] || continue
  openssl dgst -sha256 -sign "$K1" -out "$f.sig1" "$f"
  echo "→ $f.sig1"
done
echo "[sign_release] 完成（公钥：app/tool/watermark_pub.pem）"
