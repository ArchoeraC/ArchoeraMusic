#!/usr/bin/env bash
# =====================================================================
#  ArchoeraMusic 发布产物签名（支持双控分签）—— ECDSA/SHA-256 分离签名。
#
#  双控约定：
#    key1（.sig1）：CI 在受保护 `release` Environment（人工审批）用 key1 签；
#    key2（.sig2）：**维护者本地**用 key2 签好后上传进 Release（key2 绝不进 CI）。
#
#  用 ARCHOERA_WM_KEYS 选择本次用哪把（默认 1,2 都签，存在哪把签哪把）：
#    CI  ：ARCHOERA_WM_KEYS=1 + ARCHOERA_WM_KEY1_PEM
#    本地：ARCHOERA_WM_KEYS=2（用默认文件 watermark2_ec_priv.pem）
#
#  私钥来源（各自二选一）：
#    key1: 环境变量 ARCHOERA_WM_KEY1_PEM，或文件 watermark_ec_priv.pem
#    key2: 环境变量 ARCHOERA_WM_KEY2_PEM，或文件 watermark2_ec_priv.pem
#  仅 POSIX；Windows 用跨平台 Dart 版：tool/sign_release.dart。
#
#  用法：bash app/tool/sign_release.sh [dist/linux]
# =====================================================================
set -euo pipefail

KEYDIR="${ARCHOERA_WM_KEYDIR:-$HOME/.config/archoera}"
K1="${ARCHOERA_WM_KEY1_FILE:-$KEYDIR/watermark_ec_priv.pem}"
K2="${ARCHOERA_WM_KEY2_FILE:-$KEYDIR/watermark2_ec_priv.pem}"
TMP1=""; TMP2=""
cleanup() {
  [ -n "$TMP1" ] && rm -f "$TMP1"
  [ -n "$TMP2" ] && rm -f "$TMP2"
  return 0
}
trap cleanup EXIT
if [ -n "${ARCHOERA_WM_KEY1_PEM:-}" ]; then
  TMP1="$(mktemp)"; printf '%s\n' "$ARCHOERA_WM_KEY1_PEM" > "$TMP1"; chmod 600 "$TMP1"; K1="$TMP1"
fi
if [ -n "${ARCHOERA_WM_KEY2_PEM:-}" ]; then
  TMP2="$(mktemp)"; printf '%s\n' "$ARCHOERA_WM_KEY2_PEM" > "$TMP2"; chmod 600 "$TMP2"; K2="$TMP2"
fi

# 选择使用哪把密钥（默认两把都尝试）。
KEYS="${ARCHOERA_WM_KEYS:-1,2}"
use1=0; use2=0
case ",$KEYS," in *,1,*) use1=1;; esac
case ",$KEYS," in *,2,*) use2=1;; esac

have1=0; have2=0
[ "$use1" -eq 1 ] && [ -f "$K1" ] && have1=1
[ "$use2" -eq 1 ] && [ -f "$K2" ] && have2=1
if [ "$have1" -eq 0 ] && [ "$have2" -eq 0 ]; then
  echo "[sign_release] 无可用私钥（ARCHOERA_WM_KEYS=$KEYS），跳过签名（退出 0）"
  exit 0
fi
[ "$use1" -eq 1 ] && [ "$have1" -eq 0 ] && echo "[sign_release] 警告：key1 不可用（$K1）"
[ "$use2" -eq 1 ] && [ "$have2" -eq 0 ] && echo "[sign_release] 警告：key2 不可用（$K2）"

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
  if [ "$have1" -eq 1 ]; then
    openssl dgst -sha256 -sign "$K1" -out "$f.sig1" "$f"
    echo "→ $f.sig1"
  fi
  if [ "$have2" -eq 1 ]; then
    openssl dgst -sha256 -sign "$K2" -out "$f.sig2" "$f"
    echo "→ $f.sig2"
  fi
done
echo "[sign_release] 完成（公钥：app/tool/watermark_pub.pem / watermark_pub2.pem）"
