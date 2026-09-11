#!/usr/bin/env bash
# =====================================================================
#  ArchoeraMusic 低流量补签 —— 仅凭 SHA256SUMS 对**预计算摘要**签名，
#  无需下载大体积产物（网络受限场景）。
#
#  原理：ECDSA 签名对象是消息摘要；CI 的 SHA256SUMS（小文件、且已被 key1 的
#  .sig1 签名）给出各产物 SHA-256。本脚本把该摘要直接喂给 pkeyutl 签名，
#  产出的 <asset>.sig2 与「对整包签名」等价，可用标准命令验签：
#    openssl dgst -sha256 -verify watermark_pub2.pem -signature <asset>.sig2 <asset>
#
#  用法：
#    gh release download <tag> -p SHA256SUMS -D <dir> --clobber
#    ARCHOERA_WM_KEYS=2 bash app/tool/sign_release_hashes.sh <dir>
#    gh release upload <tag> <dir>/*.sig2 --clobber
#
#  <dir> 至少需含 SHA256SUMS；无需含产物文件。
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

KEYS="${ARCHOERA_WM_KEYS:-2}"
use1=0; use2=0
case ",$KEYS," in *,1,*) use1=1;; esac
case ",$KEYS," in *,2,*) use2=1;; esac

DIR="${1:?用法: sign_release_hashes.sh <含 SHA256SUMS 的目录>}"
SUMS="$DIR/SHA256SUMS"
[ -f "$SUMS" ] || { echo "缺少 $SUMS" >&2; exit 1; }

sign_digest() { # <keyfile> <hex> <out>
  local kf="$1" hex="$2" out="$3" d
  d="$(mktemp)"
  printf '%s' "$hex" | xxd -r -p > "$d"
  openssl pkeyutl -sign -inkey "$kf" -in "$d" -pkeyopt digest:sha256 -out "$out"
  rm -f "$d"
}

n=0
while read -r hex name; do
  [ -n "${hex:-}" ] || continue
  [ -n "${name:-}" ] || continue
  if [ "$use1" -eq 1 ] && [ -f "$K1" ]; then sign_digest "$K1" "$hex" "$DIR/$name.sig1"; fi
  if [ "$use2" -eq 1 ] && [ -f "$K2" ]; then sign_digest "$K2" "$hex" "$DIR/$name.sig2"; fi
  n=$((n + 1))
done < "$SUMS"

# SHA256SUMS 自身：对文件直接签（小文件）
if [ "$use1" -eq 1 ] && [ -f "$K1" ]; then openssl dgst -sha256 -sign "$K1" -out "$SUMS.sig1" "$SUMS"; fi
if [ "$use2" -eq 1 ] && [ -f "$K2" ]; then openssl dgst -sha256 -sign "$K2" -out "$SUMS.sig2" "$SUMS"; fi

echo "[sign_release_hashes] 依据 $SUMS 签了 $n 个产物（keys=$KEYS）"
