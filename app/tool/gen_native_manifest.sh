#!/bin/sh
# =====================================================================
#  ArchoeraMusic 原生库完整性清单生成（SEC-08）。
#
#  构建期对 bundled native/ 目录（及额外运行时文件）计算 SHA-256，产出
#  <native_dir>/ARCHOERA-NATIVE-MANIFEST.txt，供 Dart 运行期在
#  DynamicLibrary.open 前校验（打包态 fail-closed）。
#
#  清单格式：每行 "<64-hex-sha256>  <basename>"（两个空格分隔），按基名排序；
#  键为文件名基（库与其清单同目录），校验方只按 basename 查表。
#
#  用法：gen_native_manifest.sh <native_dir> [extra_file ...]
#    <native_dir>  安装后的 native/ 目录（其下常规文件全部纳入）
#    extra_file    额外纳入的文件（如 exe 根的可执行文件、data/app.so）
#
#  POSIX sh；`sha256sum` 优先，回退 `shasum -a 256`；出错非零退出。
# =====================================================================
set -eu

MANIFEST_NAME="ARCHOERA-NATIVE-MANIFEST.txt"

if [ "$#" -lt 1 ]; then
  echo "用法: $0 <native_dir> [extra_file ...]" >&2
  exit 2
fi

NATIVE_DIR="$1"
shift

[ -d "$NATIVE_DIR" ] || { echo "目录不存在: $NATIVE_DIR" >&2; exit 1; }

OUT="$NATIVE_DIR/$MANIFEST_NAME"
TMP="$OUT.tmp.$$"

cleanup() { rm -f "$TMP"; }
trap cleanup EXIT INT TERM

hash_file() {
  # 输出 "<hash>  <name>"；优先 sha256sum，回退 shasum -a 256。
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1"
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1"
  else
    echo "缺少 sha256sum / shasum，无法生成完整性清单" >&2
    exit 1
  fi
}

add_file() {
  f="$1"
  [ -f "$f" ] || return 0
  base=$(basename "$f")
  # 跳过清单自身与其临时文件。
  [ "$base" = "$MANIFEST_NAME" ] && return 0
  case "$base" in
    "$MANIFEST_NAME".tmp.*) return 0 ;;
  esac
  hash=$(hash_file "$f" | awk '{print $1}')
  [ -n "$hash" ] || { echo "哈希失败: $f" >&2; exit 1; }
  printf '%s  %s\n' "$hash" "$base" >> "$TMP"
}

: > "$TMP"

# native_dir 下的直接常规文件（glob 不含隐藏文件，符合预期）。
for f in "$NATIVE_DIR"/*; do
  add_file "$f"
done

# 额外文件（如 exe / AOT 库）。
for f in "$@"; do
  add_file "$f"
done

# 排序去重后落盘。
sort -u "$TMP" > "$OUT"

echo "[gen_native_manifest] 已生成 $OUT（$(wc -l < "$OUT" | tr -d ' ') 项）"
