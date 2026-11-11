#!/usr/bin/env bash
# =====================================================================
#  Linux 运行库自包含 + RUNPATH 归一化。
#
#  1) 把「发行版敏感库」的**传递依赖闭包**拷入 bundle/native/，并给内嵌库
#     加 RUNPATH=$ORIGIN。背景：引擎链接 FFmpeg、scraper 链接 TagLib，二者
#     soname 跨发行版会 bump（libavformat.so.60→.63、libtag.so.1→.2）；FFmpeg
#     还依赖大量发行版专属 codec 库。仅内嵌 FFmpeg 本体并不够。
#  2) 归一化全 bundle 的 RUNPATH（native/ 与 lib/ 下 ELF 一律 ${ORIGIN}）：
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

is_elf() { readelf -h "$1" >/dev/null 2>&1; }

# 只沿**直接 DT_NEEDED** 遍历，并且遇到 DENY_RE（系统库）就停止——
# 不能使用 `ldd` 的全量传递闭包：那会把 libcurl 的 TLS/HTTP 栈
# （libssl/libcrypto/libssh2/libnghttp2/ngtcp2/krb5…）整棵拖进 native/。
# 这些库本身是系统提供的，内嵌它们的依赖既浪费体积，又会把构建机的
# OpenSSL soname（如 .so.4）带进产物，换发行版后反而成为隐患。
direct_needed() {
  readelf -d "$1" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' || true
}

declare -A processed=()
queue=()

# 起点：发行版敏感库 + native/ 内已有的全部 ELF（FFmpeg / 模块库等）。
for f in "${targets[@]}"; do queue+=("$f"); done
while IFS= read -r -d '' f; do
  is_elf "$f" && queue+=("$f")
done < <(find "$native" -maxdepth 1 -type f -print0)

while [[ ${#queue[@]} -gt 0 ]]; do
  obj="${queue[0]}"
  queue=("${queue[@]:1}")
  [[ -n "${processed[$obj]:-}" ]] && continue
  processed[$obj]=1

  # 一次 ldd 取该对象的解析结果，但只处理它自己的直接 NEEDED。
  ldd_out="$(ldd "$obj" 2>/dev/null || true)"
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if [[ -e "$native/$name" ]]; then
      queue+=("$native/$name")
      continue
    fi
    [[ "$name" =~ $DENY_RE ]] && continue   # 系统库：不内嵌、不遍历其子树
    path="$(awk -v n="$name" '$1==n && $2=="=>" {print $3; exit}' <<<"$ldd_out")"
    [[ -n "$path" && "$path" != "not" && -f "$path" ]] || {
      echo "警告: 无法解析 ${name}（来自 $(basename "$obj")），跳过" >&2
      continue
    }
    cp -L "$path" "$native/$name"
    echo "  + 内嵌 $name  (← $path)"
    queue+=("$native/$name")
  done < <(direct_needed "$obj")
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

# 原生库完整性清单（SEC-08）：必须在**全部二进制后处理之后**生成——上面的
# 闭包收拢与 patchelf RUNPATH 改写都会改变 native/ 库的字节，提前生成即失效。
# 生成 native/ARCHOERA-NATIVE-MANIFEST.txt，供 Dart 在 DynamicLibrary.open 前
# 按 basename 校验 SHA-256（打包态 fail-closed，见 lib/services/native_integrity.dart）。
# 脚本缺失/失败不阻断打包（仅告警）。
manifest_gen="$(cd "$(dirname "${BASH_SOURCE[0]}")/../tool" 2>/dev/null && pwd)/gen_native_manifest.sh"
if [[ -f "$manifest_gen" ]]; then
  manifest_extra=()
  [[ -f "$bundle/archoera_music" ]] && manifest_extra+=("$bundle/archoera_music")
  sh "$manifest_gen" "$native" "${manifest_extra[@]}" || echo "[bundle-linux-runtime] 警告: 完整性清单生成失败" >&2
else
  echo "[bundle-linux-runtime] 警告: 未找到 gen_native_manifest.sh，跳过完整性清单" >&2
fi

