#!/usr/bin/env bash
# =====================================================================
#  ArchoeraMusic macOS 自包含化（install_name 归一化 + 依赖收拢）
#
#  背景：macOS 的 .app 里，FFI 库由 Dart 按名 dlopen（不经过 dylibbundler 的
#  DT_NEEDED 遍历），dylibbundler 只处理 -x 指定的那几个库，其余模块
#  （downloader / transcoder / log / platform / scanner / indexer …）的
#  install_name 与依赖会**残留构建机绝对路径**：
#      /Users/runner/work/.../target/release/deps/libarchoera_downloader.dylib
#  用户机上该路径不存在，加载即失败。本脚本统一纠正：
#
#   1. native/ 下每个 dylib 的 LC_ID_DYLIB → @loader_path/<basename>
#      （可执行文件同理用 -id? 不适用；只处理 Mach-O 动态库）。
#   2. 其 LC_LOAD_DYLIB 中出现「同目录已有同名文件」或「构建机绝对路径」的，
#      一律改写为 @loader_path/<basename>（文件确实内嵌时）或报错。
#   3. 若依赖只存在于构建机路径且未内嵌 → 直接失败（不猜、不静默）。
#
#  不处理主程序与 native/ 下的**子进程可执行文件**（audio-engine / vault）：
#  它们由各自构建脚本负责，改写 load command 会使现有签名失效而无法重新
#  ad-hoc 签名（Mach-O 额外代码槽）。守卫脚本会把残留暴露出来。
#
#  用法: fix-macos-loadpaths.sh <native_dir>
#  依赖: install_name_tool、otool（Xcode Command Line Tools）
#  注意：只用 bash 3.2 可用语法（macOS 自带 /bin/bash 仍是 3.2）。
# =====================================================================
set -euo pipefail
export LC_ALL=C

native="${1:-}"
[[ -n "$native" && -d "$native" ]] || {
  echo "用法: $0 <native 目录>" >&2
  exit 2
}
native="$(cd "$native" && pwd)"

for tool in otool install_name_tool; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "错误: 缺少 $tool（Xcode Command Line Tools）" >&2
    exit 2
  }
done

errors=0
changed=0
fail() {
  echo "::error::$1" >&2
  errors=$((errors + 1))
}

is_dylib() { [[ "$1" == *.dylib ]] && file -b "$1" 2>/dev/null | grep -q 'Mach-O'; }
is_build_path() {
  case "$1" in
    @* | /usr/lib/* | /System/Library/* | /System/iOSSupport/*) return 1 ;;
    /*) return 0 ;;
    *) return 1 ;;
  esac
}

shopt -s nullglob
for dylib in "$native"/*.dylib; do
  is_dylib "$dylib" || continue
  base="$(basename "$dylib")"
  rel="$base"

  # ── install_name（LC_ID_DYLIB）──────────────────────────────────
  cur_id="$(otool -D "$dylib" 2>/dev/null | tail -n +2 | head -1 || true)"
  want_id="@loader_path/$base"
  if [[ -n "$cur_id" && "$cur_id" != "$want_id" ]]; then
    if is_build_path "$cur_id" || [[ "$cur_id" == @rpath/* || "$cur_id" == @executable_path/* ]]; then
      install_name_tool -id "$want_id" "$dylib"
      echo "  id   $rel: $cur_id → $want_id"
      changed=$((changed + 1))
    fi
  fi

  # ── 依赖（LC_LOAD_DYLIB）────────────────────────────────────────
  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    [[ "$ref" == "$cur_id" ]] && continue          # 自身 install_name
    case "$ref" in
      @loader_path/* | @executable_path/*) continue ;;
      /usr/lib/* | /System/Library/* | /System/iOSSupport/*) continue ;;
    esac

    dep_base="$(basename "$ref")"
    if is_build_path "$ref"; then
      if [[ -e "$native/$dep_base" ]]; then
        install_name_tool -change "$ref" "@loader_path/$dep_base" "$dylib"
        echo "  dep  $rel: $ref → @loader_path/$dep_base"
        changed=$((changed + 1))
      else
        fail "$rel: 依赖 $ref 不在 native/ 内（需要先 dylibbundler 收拢，或补内嵌）"
      fi
      continue
    fi

    # 裸文件名 / @rpath：若同目录确有该库，统一改成 @loader_path
    if [[ "$ref" != @* ]] && [[ -e "$native/$dep_base" ]]; then
      install_name_tool -change "$ref" "@loader_path/$dep_base" "$dylib"
      echo "  dep  $rel: $ref → @loader_path/$dep_base"
      changed=$((changed + 1))
    fi
  done < <(otool -L "$dylib" 2>/dev/null | tail -n +2 | awk '{print $1}')
done

if [[ $errors -gt 0 ]]; then
  echo "macOS loadpath 归一化失败：$errors 项错误" >&2
  exit 1
fi
echo "macOS loadpath 归一化完成：$changed 处改写"
