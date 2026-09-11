#!/usr/bin/env bash
# =====================================================================
#  ArchoeraMusic 发布产物签名（权威层）—— 对 dist/linux 下每个发布包做
#  ECDSA(SHA-256) 分离签名（.sig）。签名覆盖**整包字节**：下游改名、重打包、
#  改一个字节都会导致验签失败，无法在不持有私钥的情况下伪造。
#
#  私钥同 sign_watermark.sh（$HOME/.config/archoera/watermark_ec_priv.pem）。
#  用法：bash app/tool/sign_release.sh [dist/linux]
# =====================================================================
set -euo pipefail

KEYDIR="${ARCHOERA_WM_KEYDIR:-$HOME/.config/archoera}"
PRIV="$KEYDIR/watermark_ec_priv.pem"
[ -f "$PRIV" ] || { echo "缺少私钥 $PRIV（先跑 app/tool/sign_watermark.sh）" >&2; exit 1; }
DIST="${1:-dist/linux}"
[ -d "$DIST" ] || { echo "产物目录不存在: $DIST" >&2; exit 1; }

# 汇总校验和（便于人工核对）
(
  cd "$DIST"
  # shellcheck disable=SC2012
  ls ./*.tar.gz ./*.deb ./*.rpm ./*.AppImage ./*.pkg.tar.zst 2>/dev/null \
    | xargs -r sha256sum > SHA256SUMS || true
)

for f in "$DIST"/*.tar.gz "$DIST"/*.deb "$DIST"/*.rpm "$DIST"/*.AppImage \
         "$DIST"/*.pkg.tar.zst "$DIST"/SHA256SUMS; do
  [ -f "$f" ] || continue
  openssl dgst -sha256 -sign "$PRIV" -out "$f.sig" "$f"
  echo "→ $f.sig"
done
echo "[sign_release] 完成（公钥：app/tool/watermark_pub.pem）"
