#!/usr/bin/env bash
# =====================================================================
#  Linux 运行库自包含 + RUNPATH 归一化。
#
#  1) 把「发行版敏感库」的**传递依赖闭包**拷入 bundle/native/，并给内嵌库
#     加 RUNPATH=$ORIGIN。背景：引擎链接 FFmpeg、scraper 链接 TagLib，二者
#     soname 跨发行版会 bump（libavformat.so.60→.63、libtag.so.1→.2）；FFmpeg
#     还依赖大量发行版专属 codec 库。仅内嵌 FFmpeg 本体并不够。
#  2) 归一化全 bundle 的 RUNPATH（native/ 与 lib/ 下 ELF 一律 $ORIGIN）：
#     去掉构建期泄漏的临时路径（如 $HOME/.local/ffmpeg-minimal/lib、Flutter
#     ephemeral 目录），否则 Fedora rpmbuild 的 check-rpaths 会直接报错失败。
#
#  只收「发行版敏感库」的闭包（引擎/scraper），不扫描全部原生库：curl/
#  ssl/sqlite 等 ABI 稳定库由系统提供（见打包 depends），避免双份加载。
#  GUI/驱动/系统集成库（X11/GL/va/systemd/dbus/glib 等）即使出现在闭包里
#  也不内嵌——它们必须与系统共享。
#
#  用法: bundle-linux-runtime.sh <bundle 目录>
#  依赖: ldd（binutils）、patchelf
# =====================================================================
set -euo pipefail

bundle="${1:?用法: bundle-linux-runtime.sh <bundle 目录>}"
if [[ ! -d "$bundle" ]]; then
  echo "错误: bundle 目录不存在: $bundle" >&2
  exit 1
fi
bundle="$(cd "$bundle" && pwd)"
native="$bundle/native"
if [[ ! -d "$native" ]]; then
  echo "错误: 缺 native/ 目录: $native" >&2
  exit 1
fi

SENSITIVE_LIBS=(libarchoera_mediaengine.so libarchoera_scraper.so)

# 不内嵌：glibc / gcc runtime + GUI/驱动/系统集成 + ABI 稳定第三方库
DENY_RE='^(ld-linux[^/]*|libc|libm|libpthread|libdl|librt|libgcc_s|libstdc\+\+|libnsl|libresolv|libutil|libcrypt|libX11[^/]*|libXext[^/]*|libXfixes[^/]*|libXrender[^/]*|libXau[^/]*|libxcb[^/]*|libXdmcp[^/]*|libGL[^/]*|libEGL[^/]*|libGLX[^/]*|libGLdispatch|libGLESv2|libgbm|libdrm[^/]*|libva[^/]*|libvdpau[^/]*|libvpl|libwayland[^/]*|libsystemd|libdbus-1|libglib[^/]*|libgobject|libgio[^/]*|libgtk[^/]*|libgdk[^/]*|libpango[^/]*|libcairo[^/]*|libatk[^/]*|libfontconfig|libfreetype|libharfbuzz|libssl|libcrypto|libcurl|libsqlite3|libzstd|libz|libpcre[^/]*|libselinux|libmount|libblkid|libffi|libuuid|libgcc|libexpat)\.so'

targets=()
for lib in "${SENSITIVE_LIBS[@]}"; do
  [[ -f "$native/$lib" ]] && targets+=("$native/$lib")
done
if [[ ${#targets[@]} -eq 0 ]]; then
  echo "提示: native/ 内未找到发行版敏感库，跳过闭包收拢" >&2
fi

collect_deps() {
  local f
  for f in "$@"; do ldd "$f" 2>/dev/null || true; done \
    | awk '/=>/ && $3 ~ /^\// {print $3}'
}

# 迭代到不动点（ldd 已含传递闭包，多轮仅作保险）
for _round in 1 2 3; do
  [[ ${#targets[@]} -gt 0 ]] || break
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

# 归一化 RUNPATH：native/ 与 lib/ 下的 ELF 一律 $ORIGIN
# （主可执行 archoera_music 的 $ORIGIN/lib 是必要的，不在处理范围内）
if command -v patchelf >/dev/null 2>&1; then
  scan_dirs=("$native")
  [[ -d "$bundle/lib" ]] && scan_dirs+=("$bundle/lib")
  find "${scan_dirs[@]}" -maxdepth 1 -type f \
    \( -name '*.so*' -o -perm -u+x \) -print0 2>/dev/null \
    | while IFS= read -r -d '' f; do
        cur="$(patchelf --print-rpath "$f" 2>/dev/null || true)"
        [[ "$cur" == '$ORIGIN' ]] && continue
        patchelf --set-rpath '$ORIGIN' "$f" 2>/dev/null || true
      done
  echo "[bundle-linux-runtime] 已归一化 native/ 与 lib/ 的 RUNPATH=\$ORIGIN"
else
  echo "警告: 未找到 patchelf，跳过 RUNPATH 归一化（rpm/arch 打包可能因 check-rpaths 失败）" >&2
fi

echo "[bundle-linux-runtime] 完成；native/ 内嵌库："
find "$native" -maxdepth 1 -type f -name '*.so*' -printf '  %f\n' | sort
