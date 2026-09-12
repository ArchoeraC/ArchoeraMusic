#!/usr/bin/env bash
# =====================================================================
#  Linux 运行库自包含：把「发行版敏感库」的**传递依赖闭包**一并拷入
#  bundle/native/，并给内嵌库加 RUNPATH=$ORIGIN。
#
#  背景：引擎链接 FFmpeg、scraper 链接 TagLib，二者 soname 跨发行版会 bump
#  （libavformat.so.60→.63、libtag.so.1→.2）；FFmpeg 还依赖大量发行版专属
#  codec 库（libx264.so.164、libx265.so.199、libvpx.so.9、libxml2.so.2 …）。
#  仅内嵌 FFmpeg 本体并不够：本体没有 RUNPATH 找不到同目录兄弟库，其传递
#  依赖也缺失。本脚本把整条闭包收进来并统一加 $ORIGIN，产物不再依赖目标
#  发行版的 FFmpeg/TagLib 版本，防止系统库差异/升级导致加载断裂。
#
#  只收「发行版敏感库」的闭包（引擎/scraper），不扫描全部原生库：curl/
#  ssl/sqlite/zmq 等 ABI 稳定库由系统提供（见打包 depends），避免双份加载。
#  GUI/驱动/系统集成库（X11/GL/va/vdpau/systemd/dbus/glib 等）即使出现在
#  闭包里也不内嵌——它们必须与系统共享，自带反而危险。
#
#  用法: bundle-linux-runtime.sh <bundle>/native [额外待收拢的库…]
#  依赖: ldd（binutils）、patchelf（设置 RUNPATH）
# =====================================================================
set -euo pipefail

native="${1:?用法: bundle-linux-runtime.sh <bundle>/native [libs…]}"
shift || true
if [[ ! -d "$native" ]]; then
  echo "错误: native 目录不存在: $native" >&2
  exit 1
fi
native="$(cd "$native" && pwd)"

# 待收拢闭包的「发行版敏感库」（缺失则跳过）
SENSITIVE_LIBS=("$@")
if [[ ${#SENSITIVE_LIBS[@]} -eq 0 ]]; then
  SENSITIVE_LIBS=(libarchoera_mediaengine.so libarchoera_scraper.so)
fi

# 不内嵌：glibc / gcc runtime + GUI/驱动/系统集成 + ABI 稳定第三方库
DENY_RE='^(ld-linux[^/]*|libc|libm|libpthread|libdl|librt|libgcc_s|libstdc\+\+|libnsl|libresolv|libutil|libcrypt|libX11[^/]*|libXext[^/]*|libXfixes[^/]*|libXrender[^/]*|libXau[^/]*|libxcb[^/]*|libXdmcp[^/]*|libGL[^/]*|libEGL[^/]*|libGLX[^/]*|libGLdispatch|libGLESv2|libgbm|libdrm[^/]*|libva[^/]*|libvdpau[^/]*|libvpl|libwayland[^/]*|libsystemd|libdbus-1|libglib[^/]*|libgobject|libgio[^/]*|libgtk[^/]*|libgdk[^/]*|libpango[^/]*|libcairo[^/]*|libatk[^/]*|libfontconfig|libfreetype|libharfbuzz|libssl|libcrypto|libcurl|libsqlite3|libzstd|libz|libpcre[^/]*|libselinux|libmount|libblkid|libffi|libuuid|libgcc|libexpat)\.so'

targets=()
for lib in "${SENSITIVE_LIBS[@]}"; do
  if [[ -f "$native/$lib" ]]; then
    targets+=("$native/$lib")
  else
    echo "提示: 未找到 $native/$lib，跳过" >&2
  fi
done
[[ ${#targets[@]} -gt 0 ]] || { echo "无可收拢的库，退出" >&2; exit 0; }

collect_deps() {
  local f
  for f in "$@"; do ldd "$f" 2>/dev/null || true; done \
    | awk '/=>/ && $3 ~ /^\// {print $3}'
}

# 迭代到不动点（ldd 已含传递闭包，多轮仅作保险）
for _round in 1 2 3; do
  before="$(find "$native" -maxdepth 1 -type f -printf '%f\n' | sort | md5sum)"
  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    name="$(basename "$dep")"
    [[ "$name" =~ $DENY_RE ]] && continue
    [[ -e "$native/$name" ]] && continue
    cp -L "$dep" "$native/$name"
    echo "  + 内嵌 $name  (← $dep)"
  done < <(collect_deps "${targets[@]}" | sort -u)
  after="$(find "$native" -maxdepth 1 -type f -printf '%f\n' | sort | md5sum)"
  [[ "$before" == "$after" ]] && break
done

# 统一 RUNPATH=$ORIGIN：内嵌库互相解析、且优先于系统库
if command -v patchelf >/dev/null 2>&1; then
  find "$native" -maxdepth 1 -type f -name '*.so*' | while IFS= read -r f; do
    cur="$(patchelf --print-rpath "$f" 2>/dev/null || true)"
    # 只在已恰好是 $ORIGIN 时跳过；否则重写（顺带清掉构建期泄漏的前缀路径）
    [[ "$cur" == '$ORIGIN' ]] && continue
    patchelf --set-rpath '$ORIGIN' "$f" 2>/dev/null || true
  done
  echo "[bundle-linux-runtime] 已为 native/ 内库设置 RUNPATH=\$ORIGIN"
else
  echo "警告: 未找到 patchelf，跳过 RUNPATH 设置（内嵌库可能无法互相解析）" >&2
fi

echo "[bundle-linux-runtime] 完成；native/ 内 FFmpeg/TagLib 闭包："
find "$native" -maxdepth 1 -type f -name '*.so*' -printf '  %f\n' | sort
