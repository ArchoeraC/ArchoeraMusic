#!/bin/sh
# =====================================================================
#  ArchoeraMusic 原生完整性清单签名（SEC-08）—— key1 ECDSA/SHA-256 分离签名。
#
#  对 <dir>/ARCHOERA-NATIVE-MANIFEST.txt 原文签名，产出同目录
#  <dir>/ARCHOERA-NATIVE-MANIFEST.sig1（DER）；运行期 NativeIntegrity 用
#  二进制内嵌公钥验签（app/tool/watermark_pub.pem / app/lib/app/watermark.dart）。
#
#  私钥来源（与 sign_release.sh 一致，二选一）：
#    - 环境变量 ARCHOERA_WM_KEY1_PEM（CI secret：整个 PEM 内容，推荐）
#    - 文件 ARCHOERA_WM_KEY1_FILE / 默认 ~/.config/archoera/watermark_ec_priv.pem
#
#  用法：sign_native_manifest.sh <dir>
#    <dir>  含 ARCHOERA-NATIVE-MANIFEST.txt 的目录（如 bundle 的 native/）。
#
#  POSIX sh；set -eu；缺少私钥/清单或 openssl 时非零退出，绝不打印私钥材料。
# =====================================================================
set -eu

MANIFEST_NAME="ARCHOERA-NATIVE-MANIFEST.txt"
SIG_NAME="ARCHOERA-NATIVE-MANIFEST.sig1"

if [ "$#" -lt 1 ]; then
  echo "用法: $0 <dir>" >&2
  exit 2
fi

DIR="$1"
[ -d "$DIR" ] || { echo "目录不存在: $DIR" >&2; exit 1; }

MANIFEST="$DIR/$MANIFEST_NAME"
OUT="$DIR/$SIG_NAME"
[ -f "$MANIFEST" ] || { echo "缺少清单: $MANIFEST" >&2; exit 1; }

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

command -v openssl >/dev/null 2>&1 || { echo "缺少 openssl，无法签名" >&2; exit 1; }

openssl dgst -sha256 -sign "$K1" -out "$OUT" "$MANIFEST"
echo "[sign_native_manifest] 已签名 $OUT"
