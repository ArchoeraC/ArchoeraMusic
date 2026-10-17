#!/usr/bin/env bash
# =====================================================================
#  ArchoeraMusic 发布产物签名 —— ECDSA/SHA-256 分离签名（<asset>.sig1）。
#
#  对产物目录下**全部**发布资产签 `.sig1`（含 SBOM、`SHA256SUMS`；仅排除既有
#  `.sig1` 与分发公钥 `ARCHOERA_PUBKEY.pem`），并把全部资产写入 `SHA256SUMS`。
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

# 汇总校验和（便于人工核对）：覆盖**全部**发布资产（含 SBOM；分发公钥也入清单）。
# 排除：既有 `.sig1` 与清单自身（`SHA256SUMS` 由其 `.sig1` 签名保护）。
(
  cd "$DIST"
  for f in ./*; do
    [ -f "$f" ] || continue
    case "$f" in ./*.sig1 | ./SHA256SUMS) continue ;; esac
    sha256sum "$f"
  done | LC_ALL=C sort -k2 > SHA256SUMS
)

# 逐文件签名：**全部**资产（含 SBOM、`SHA256SUMS`），只排除既有 `.sig1` 与分发
# 公钥（`ARCHOERA_PUBKEY.pem` 本身无需签名，但已列入 `SHA256SUMS`）。
for f in "$DIST"/*; do
  [ -f "$f" ] || continue
  case "$f" in *.sig1 | *ARCHOERA_PUBKEY.pem) continue ;; esac
  openssl dgst -sha256 -sign "$K1" -out "$f.sig1" "$f"
  echo "→ $f.sig1"
done
echo "[sign_release] 完成（公钥：app/tool/watermark_pub.pem）"
