#!/usr/bin/env bash
# =====================================================================
#  ArchoeraMusic 防伪签名 —— 生成/使用离线私钥，对规范负载签名，
#  输出可粘贴进 app/lib/app/watermark.dart 的常量。
#
#  私钥默认位置：$HOME/.config/archoera/watermark_ec_priv.pem（勿入库、离线备份）。
#  公钥可随仓库发布（app/tool/watermark_pub.pem），供第三方独立验证。
#
#  用法：bash app/tool/sign_watermark.sh
# =====================================================================
set -euo pipefail

KEYDIR="${ARCHOERA_WM_KEYDIR:-$HOME/.config/archoera}"
PRIV="$KEYDIR/watermark_ec_priv.pem"
PAYLOAD="${ARCHOERA_WM_PAYLOAD:-ARCHOERA DESIGNED|ArchoeraMusic|BetaStudio2|AGPL-3.0-or-later}"

mkdir -p "$KEYDIR"
if [ ! -f "$PRIV" ]; then
  echo "[watermark] 生成新的 ECDSA P-256 私钥: $PRIV（请离线备份，切勿提交）"
  openssl ecparam -name prime256v1 -genkey -noout -out "$PRIV"
  chmod 600 "$PRIV"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf '%s' "$PAYLOAD" > "$TMP/payload.bin"
openssl dgst -sha256 -sign "$PRIV" -out "$TMP/sig.der" "$TMP/payload.bin"

PUBHEX="$(openssl ec -in "$PRIV" -pubout -conv_form uncompressed -outform DER 2>/dev/null \
  | tail -c 65 | xxd -p -c 200)"
SIGHEX="$(xxd -p -c 400 "$TMP/sig.der")"

echo
echo "把以下常量更新进 app/lib/app/watermark.dart："
echo "  archoeraWatermarkPayload  = '$PAYLOAD'"
echo "  archoeraWatermarkPubKeyHex = '$PUBHEX'"
echo "  archoeraWatermarkSigDerHex = '$SIGHEX'"
echo
echo -n "openssl 自检: "
openssl dgst -sha256 -verify <(openssl ec -in "$PRIV" -pubout 2>/dev/null) \
  -signature "$TMP/sig.der" "$TMP/payload.bin"
