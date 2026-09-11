#!/usr/bin/env bash
# =====================================================================
#  ArchoeraMusic 发布产物**双签名验签** —— 用仓库两把公开公钥
#  （app/tool/watermark_pub.pem、watermark_pub2.pem）验证 <file>.sig1/.sig2。
#  **双控策略：两份签名都必须存在且有效**，任一缺失/失败即判定非官方。
#
#  用法：bash app/tool/verify_release.sh [dist/linux]
# =====================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUB1="$HERE/watermark_pub.pem"
PUB2="$HERE/watermark_pub2.pem"
DIST="${1:-dist/linux}"
[ -f "$PUB1" ] || { echo "缺少公钥 $PUB1" >&2; exit 1; }
[ -f "$PUB2" ] || { echo "缺少公钥 $PUB2" >&2; exit 1; }
[ -d "$DIST" ] || { echo "产物目录不存在: $DIST" >&2; exit 1; }

fail=0
for f in "$DIST"/*.tar.gz "$DIST"/*.tar.xz "$DIST"/*.deb "$DIST"/*.rpm \
         "$DIST"/*.AppImage "$DIST"/*.pkg.tar.zst "$DIST"/*.zip "$DIST"/*.exe \
         "$DIST"/SHA256SUMS; do
  [ -f "$f" ] || continue
  s1="MISSING"; s2="MISSING"
  [ -f "$f.sig1" ] && { openssl dgst -sha256 -verify "$PUB1" -signature "$f.sig1" "$f" >/dev/null 2>&1 && s1=OK || s1=BAD; }
  [ -f "$f.sig2" ] && { openssl dgst -sha256 -verify "$PUB2" -signature "$f.sig2" "$f" >/dev/null 2>&1 && s2=OK || s2=BAD; }
  if [ "$s1" = OK ] && [ "$s2" = OK ]; then
    echo "OK   key1=$s1 key2=$s2  $f"
  else
    echo "BAD  key1=$s1 key2=$s2  $f"
    fail=1
  fi
done
exit $fail
