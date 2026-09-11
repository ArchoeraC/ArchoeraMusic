#!/usr/bin/env bash
# =====================================================================
#  ArchoeraMusic 发布产物验签 —— 用仓库公开公钥（app/tool/watermark_pub.pem）
#  验证 dist 下每个 *.sig。任何人可据此判断产物是否官方签发。
#
#  用法：bash app/tool/verify_release.sh [dist/linux]
# =====================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUB="$HERE/watermark_pub.pem"
DIST="${1:-dist/linux}"
[ -f "$PUB" ] || { echo "缺少公钥 $PUB" >&2; exit 1; }
[ -d "$DIST" ] || { echo "产物目录不存在: $DIST" >&2; exit 1; }

fail=0
for f in "$DIST"/*.tar.gz "$DIST"/*.deb "$DIST"/*.rpm "$DIST"/*.AppImage \
         "$DIST"/*.pkg.tar.zst "$DIST"/SHA256SUMS; do
  [ -f "$f" ] || continue
  if [ ! -f "$f.sig" ]; then
    echo "MISSING  $f（无 .sig）"
    fail=1
    continue
  fi
  if openssl dgst -sha256 -verify "$PUB" -signature "$f.sig" "$f" >/dev/null 2>&1; then
    echo "OK       $f"
  else
    echo "BAD      $f"
    fail=1
  fi
done
exit $fail
