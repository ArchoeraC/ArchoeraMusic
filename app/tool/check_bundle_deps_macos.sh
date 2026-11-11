#!/usr/bin/env bash
# =====================================================================
#  ArchoeraMusic 发布依赖守卫（macOS .app / Mach-O）
#
#  Linux 侧对应脚本为 app/tool/check_bundle_deps.sh；这里是它的 Mach-O 版本。
#  逐文件检查 .app 内的架构与加载路径：
#
#   1. 每个 LC_LOAD_DYLIB 必须是以下之一，否则失败（用户机大概率加载不到）：
#        - 系统库（/usr/lib/…、/System/Library/…，macOS 自带、ABI 稳定）
#        - @loader_path / @executable_path 相对路径，且目标文件确实存在
#        - 同目录内已内嵌的库（裸文件名，如 subsonic 的 c-shared 产物）
#        - 自身 install_name（LC_ID_DYLIB 引用了自己，如 libe_sqlite3 的
#          "./bin/e_sqlite3/mac/arm64/libe_sqlite3.dylib"）
#   2. 禁止出现构建机绝对路径（/Users/…、/opt/homebrew/…、/usr/local/…），
#      这类路径在用户机上不存在，是「装完打不开」的头号原因；dylibbundler
#      没覆盖到的模块（downloader / transcoder / audio-engine 等）最易漏。
#   3. 目录里**实际存在**的 libssl / libcrypto / libcurl（含 libcrypto.N.dylib
#      这类改过名的内嵌副本），以及任何指向它们的加载路径，都直接失败：加密与
#      HTTP 均为内嵌 Rust 静态栈，编进来的 OpenSSL 只会带来 soname 升级风险。
#   4. @rpath 引用要求 rpath 能解析到 bundle 内（@loader_path/@executable_path）。
#   5. 架构：native/ 下每个 Mach-O 必须且只能是目标架构（arm64 / x86_64），
#      防止误塞 universal 或另一半架构的库（Apple Silicon 混装会直接拒载）。
#   6. 关键发布文件齐全，且原生清单覆盖全部 dylib。
#
#  用法:
#    app/tool/check_bundle_deps_macos.sh <archoera_music.app> [--arch arm64|x86_64]
#
#  退出码: 0 通过；1 存在错误；2 用法/工具缺失。
# =====================================================================
set -euo pipefail
export LC_ALL=C

app="${1:-}"
[[ -n "$app" && -d "$app" ]] || {
  echo "用法: $0 <archoera_music.app> [--arch arm64|x86_64]" >&2
  exit 2
}
shift
app="$(cd "$(dirname "$app")" && pwd)/$(basename "$app")"

want_arch=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) [[ $# -ge 2 ]] || { echo "--arch 需要一个参数" >&2; exit 2; }; want_arch="$2"; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done
if [[ -n "$want_arch" ]]; then
  case "$want_arch" in
    arm64|x86_64) ;;
    *) echo "错误: --arch 只支持 arm64 / x86_64（收到 $want_arch）" >&2; exit 2 ;;
  esac
fi

for tool in otool file; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "错误: 缺少 $tool（Xcode Command Line Tools）" >&2
    exit 2
  }
done

errors=0
declare -a system_refs=()
fail() {
  echo "::error::$*" >&2
  errors=$((errors + 1))
}

is_system_path() {
  case "$1" in
    /usr/lib/* | /System/Library/* | /System/iOSSupport/*) return 0 ;;
    *) return 1 ;;
  esac
}

is_build_path() {
  case "$1" in
    @*) return 1 ;;
    /*) return 0 ;;
    *) return 1 ;;
  esac
}

is_forbidden() {
  case "$(basename "$1")" in
    libssl* | libcrypto* | libcurl*) return 0 ;;
    *) return 1 ;;
  esac
}

native="$app/Contents/native"
exe="$app/Contents/MacOS/archoera_music"

require_file() { [[ -e "$1" ]] || fail "缺少发布必需文件：${1#"$app"/}"; }
require_file "$exe"
require_file "$native/archoera-audio-engine"
require_file "$native/archoera-vault"
require_file "$native/libarchoera_mediaengine.dylib"
require_file "$native/libarchoera_scraper.dylib"
require_file "$native/scanner-ffi.dylib"
require_file "$native/indexer-ffi.dylib"
require_file "$native/libe_sqlite3.dylib"
require_file "$native/ARCHOERA-NATIVE-MANIFEST.txt"

is_macho() { file -b "$1" 2>/dev/null | grep -q 'Mach-O'; }

macho_archs() {
  # 统一输出空格分隔的架构列表（arm64 / x86_64）。
  # 先用 file(1)（跨平台稳定），缺失时退回 lipo。
  local f="$1" a
  if command -v file >/dev/null 2>&1; then
    a="$(file -b "$f" 2>/dev/null)" || a=""
    if [[ "$a" == *"universal binary"* || "$a" == *"fat file"* ]]; then
      printf '%s\n' "universal"
      return 0
    fi
    for a in arm64e arm64 x86_64; do
      [[ "$a" == arm64e ]] && continue   # arm64e 不单独出包
      if [[ "$(file -b "$f" 2>/dev/null)" == *" $a "* || "$(file -b "$f" 2>/dev/null)" == *"$a dynamically"* || "$(file -b "$f" 2>/dev/null)" == *"$a executable"* ]]; then
        printf '%s\n' "$a"
        return 0
      fi
    done
  fi
  if command -v lipo >/dev/null 2>&1; then
    lipo -archs "$f" 2>/dev/null | tr ' ' '\n' | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//'
  fi
}

id_name() {
  # LC_ID_DYLIB 的名字（dylib 自身 install_name）
  otool -D "$1" 2>/dev/null | tail -n +2 | head -1
}

rpaths_of() {
  otool -l "$1" 2>/dev/null | awk '
    /cmd LC_RPATH/ { want=1; next }
    want && /path / { print $2; want=0 }'
}

# 把加载路径解析成带绝对路径的数组（bundle 内候选）
resolve_refs() {
  local dir="$1" ref="$2" rp
  case "$ref" in
    @loader_path/*) printf '%s\n' "$dir/${ref#@loader_path/}" ;;
    @executable_path/*) printf '%s\n' "$app/Contents/MacOS/${ref#@executable_path/}" ;;
    @rpath/*)
      while IFS= read -r rp; do
        [[ -n "$rp" ]] || continue
        case "$rp" in
          @loader_path*) printf '%s\n' "$dir/${rp#@loader_path}/${ref#@rpath/}" ;;
          @executable_path*)
            rp="${rp#@executable_path}"
            if [[ -z "$rp" ]]; then
              printf '%s\n' "$app/Contents/MacOS/${ref#@rpath/}"
            else
              printf '%s\n' "$app/Contents/MacOS${rp}/${ref#@rpath/}"
            fi
            ;;
        esac
      done < <(rpaths_of "$3")
      ;;
    /*) printf '%s\n' "$ref" ;;
    *) printf '%s\n' "$dir/$ref" ;;
  esac
}

mapfile -t files < <(find "$app/Contents/MacOS" "$native" -type f 2>/dev/null | LC_ALL=C sort)

for f in "${files[@]}"; do
  is_macho "$f" || continue
  rel="${f#"$app"/}"
  dir="$(dirname "$f")"

  # 内嵌的 OpenSSL / libcurl 副本：无论谁引用都不允许留在包里
  bundled_forbidden=0
  if is_forbidden "$f"; then
    fail "$rel: 包内出现 $(basename "$f")（加密/HTTP 已改为内嵌 Rust 静态栈，不应内嵌 OpenSSL/libcurl）"
    bundled_forbidden=1
  fi

  archs="$(macho_archs "$f")"
  if [[ -n "$want_arch" && "$archs" != "$want_arch" ]]; then
    fail "$rel: 架构为 '${archs:-<未知>}'，期望 '$want_arch'"
  fi

  self_id="$(id_name "$f")"

  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    base="$(basename "$ref")"

    # 自身副本已按「包内出现」报过一次，不再重复
    if [[ $bundled_forbidden -eq 1 ]]; then
      continue
    fi
    if is_forbidden "$ref"; then
      fail "$rel: 禁止依赖 $ref（OpenSSL/libcurl 必须是内嵌 Rust 静态栈）"
      continue
    fi

    # 自身 install_name：不是「加载」，跳过
    [[ -n "$self_id" && "$ref" == "$self_id" ]] && continue

    if is_system_path "$ref"; then
      system_refs+=("$base")
      continue
    fi

    if is_build_path "$ref"; then
      fail "$rel: 含构建机绝对路径 $ref（用户机不存在；需改写为 @loader_path 或内嵌）"
      continue
    fi

    mapfile -t cands < <(resolve_refs "$dir" "$ref" "$f")
    if [[ ${#cands[@]} -eq 0 ]]; then
      fail "$rel: @rpath 引用 $ref 无法解析（dylib 缺 LC_RPATH 或 rpath 指向构建机）"
      continue
    fi
    found=0
    for c in "${cands[@]}"; do
      [[ -e "$c" ]] && { found=1; break; }
    done
    if [[ $found -eq 0 ]]; then
      fail "$rel: 依赖 $ref 无法解析（bundle 内缺少 ${cands[0]#"$app"/}）；候选：${cands[*]}"
    fi
  done < <(otool -L "$f" 2>/dev/null | tail -n +2 | awk '{print $1}')
done

# 原生清单须覆盖 native/ 下所有 dylib（Dart 侧按清单 fail-closed 校验）
manifest="$native/ARCHOERA-NATIVE-MANIFEST.txt"
if [[ -f "$manifest" ]]; then
  for f in "$native"/*.dylib; do
    [[ -e "$f" ]] || continue
    grep -q "  $(basename "$f")\$" "$manifest" \
      || fail "原生清单缺少 $(basename "$f")（gen_native_manifest.sh 未覆盖）"
  done
fi

if [[ $errors -gt 0 ]]; then
  echo "macOS 依赖守卫失败：$errors 项错误" >&2
  exit 1
fi

trim() { sed '/^$/d' | LC_ALL=C sort -u; }
printf '%s\n' "${system_refs[@]}" 2>/dev/null | trim > "$app/Contents/ARCHOERA-SYSTEM-DEPS.txt"
echo "macOS 依赖守卫通过：$(trim < "$app/Contents/ARCHOERA-SYSTEM-DEPS.txt" | wc -l | tr -d ' ') 个系统库引用，" \
  "架构 $([[ -n "$want_arch" ]] && echo "$want_arch" || echo '未限定')"
