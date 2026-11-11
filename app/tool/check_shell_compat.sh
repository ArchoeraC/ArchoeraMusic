#!/usr/bin/env bash
# =====================================================================
#  shell 兼容性门禁（macOS = bash 3.2）
#
#  为什么需要它：macOS 自带的 /bin/bash 永远是 3.2.57（Apple 因 GPLv3 不升级），
#  GitHub 的 macOS runner 也只装 3.2（runner-images#12868 明确拒绝升级）。
#  因此 macOS 上执行的脚本不能用 bash 4+ 语法，常见坑：
#
#    - mapfile / readarray
#    - declare -A / declare -n（关联数组、nameref）
#    - ${var^^} / ${var,,} / ${var@Q} 等 4.x 参数展开
#    - shopt -s globstar / ** 递归 glob
#
#  另外：脚本启用 set -u 时，"${arr[@]}" 对**空数组**在 3.2 下会报
#  unbound variable 并中止。数组可能为空就先判长度，或用标量。
#
#  Linux/Windows 侧是 bash 5，但脚本是跨平台共享的，故统一按 3.2 校验。
#
#  用法:
#    bash app/tool/check_shell_compat.sh            # 校验默认清单
#    bash app/tool/check_shell_compat.sh <文件>...  # 只校验指定文件
#
#  退出码: 0 通过；1 发现 3.2 不兼容用法；2 用法/工具缺失。
# =====================================================================
set -uo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# 默认清单：在 macOS 上执行（或可能被执行）的脚本。
default_files=(
  "$ROOT/packaging/macos/package.sh"
  "$ROOT/app/tool/check_bundle_deps_macos.sh"
  "$ROOT/app/tool/check_shell_compat.sh"
  "$ROOT/app/tool/fix-macos-loadpaths.sh"
  "$ROOT/app/tool/verify_macos.sh"
  "$ROOT/app/tool/gen_native_manifest.sh"
  "$ROOT/app/tool/sign_native_manifest.sh"
  "$ROOT/app/tool/verify_release.sh"
  "$ROOT/app/tool/sign_release.sh"
  "$ROOT/app/core/build-macos.sh"
  "$ROOT/app/core/bundle-licenses.sh"
  "$ROOT/app/core/build-ffmpeg-minimal.sh"
)

if [[ $# -gt 0 ]]; then
  files=("$@")
else
  files=("${default_files[@]}")
fi

# 需要拦截的 3.2 不支持写法（POSIX ERE）；只匹配会被执行的行，整行注释跳过。
readonly PATTERNS=(
  '(^|[^A-Za-z_.-])(mapfile|readarray)([[:space:]]|$)'
  '(declare|typeset|local)[[:space:]]+-[A-Za-z]*[An]([[:space:]]|$)'
  '\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(\^\^|,,)'
  '\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?@[QEPAaKkLuU]'
  'shopt[[:space:]]+-s[[:space:]]+globstar'
)

errors=0
fail() {
  printf '::error file=%s,line=%s::%s\n' "$1" "$2" "$3" >&2
  errors=$((errors + 1))
}

checked=0
for f in "${files[@]}"; do
  [[ -f "$f" ]] || { echo "跳过（不存在）: $f" >&2; continue; }
  checked=$((checked + 1))
  rel="${f#"$ROOT"/}"
  lineno=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in
      '#'*) continue ;;
    esac
    for re in "${PATTERNS[@]}"; do
      if printf '%s' "$line" | grep -Eq "$re"; then
        fail "$rel" "$lineno" "bash 3.2（macOS）不支持：${trimmed:0:100}"
      fi
    done
  done < "$f"

  # 语法兜底：POSIX 模式解析（真正的 3.2 校验只能在 macOS 上做，这里挡明显错误）。
  if ! bash --posix -n "$f" 2>/dev/null; then
    fail "$rel" "?" "语法检查未通过（bash --posix -n）"
  fi
done

if [[ $errors -gt 0 ]]; then
  echo "shell 兼容性检查失败：$errors 项（目标 bash 3.2 / macOS）" >&2
  exit 1
fi
echo "shell 兼容性检查通过：$checked 个脚本符合 bash 3.2（macOS）"
