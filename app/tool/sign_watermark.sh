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

# 安全护栏：本脚本会打印私钥材料（供你配置 CI Secret），**禁止在 CI/公共日志中运行**。
if [ -n "${CI:-}" ]; then
  echo "拒绝在 CI 环境运行 sign_watermark.sh（会打印私钥材料）。密钥轮换请本地执行。" >&2
  exit 1
fi

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

# CI / 发布签名用的私钥（切勿公开、切勿入库）。推荐存成 GitHub Secret：
#   ARCHOERA_WM_PRIVKEY_PEM = 整个 PEM 文件内容（POSIX/openssl 路径用）
# 另附私钥标量 hex，供跨平台 Dart 版（tool/sign_release.dart）经
#   ARCHOERA_WM_PRIVKEY_D 使用。
DHEX="$(openssl ec -in "$PRIV" -text -noout 2>/dev/null \
  | awk '/priv:/{f=1;next} /pub:/{f=0} f' | tr -d ' :\n')"
echo
echo "⚠ 以下为私钥材料（仅用于配置 CI Secret，勿打印到公共日志）："
echo "  ARCHOERA_WM_PRIVKEY_PEM = <$PRIV 的完整内容>"
echo "  ARCHOERA_WM_PRIVKEY_D   = $DHEX"
echo
echo -n "openssl 自检: "
openssl dgst -sha256 -verify <(openssl ec -in "$PRIV" -pubout 2>/dev/null) \
  -signature "$TMP/sig.der" "$TMP/payload.bin"
