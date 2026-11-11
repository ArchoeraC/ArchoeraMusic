#!/usr/bin/env bash
# =====================================================================
#  ArchoeraMusic 发布依赖守卫（Linux ELF bundle）
#
#  发布前逐文件检查 bundle 内的 ELF：
#   1. 每个 DT_NEEDED 必须已内嵌在 bundle（native/、lib/ 或同目录），或命中
#      「系统库允许清单」；未登记的系统依赖直接失败，逼开发者显式决策。
#   2. 已内嵌的库必须**实际解析到 bundle 内**（防止 RUNPATH 丢失后被构建机的
#      系统库静默顶替——同一产物换发行版就会启动失败）。
#   3. 禁止直接依赖 libssl / libcrypto / libcurl（加密为 Rust staticlib、
#      HTTP 为 reqwest + rustls、scanner 曲目 id 为托管 MD5）。
#   4. RUNPATH 只允许 $ORIGIN 相对路径，防止把构建机绝对路径带进产物
#      （rpm/arch 的 check-rpaths 也会因此报错）。
#   5. 检查 NativeAOT 通过 dlopen 使用的伴随库（libe_sqlite3）与关键可执行文件。
#
#  用法:
#    app/tool/check_bundle_deps.sh <bundle 目录> [--allow-extra 'libfoo.so.1 ...']
#
#  退出码: 0 通过；1 存在错误；2 用法/工具缺失。
# =====================================================================
set -euo pipefail
export LC_ALL=C

bundle="${1:-}"
if [[ -z "$bundle" || ! -d "$bundle" ]]; then
  echo "用法: $0 <bundle 目录> [--allow-extra 'libfoo.so.1 ...']" >&2
  exit 2
fi
bundle="$(cd "$bundle" && pwd)"
shift

extra_allow=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-extra)
      [[ $# -ge 2 ]] || { echo "--allow-extra 需要一个参数" >&2; exit 2; }
      # shellcheck disable=SC2206  # 允许一次传多个 soname
      extra_allow+=($2)
      shift 2
      ;;
    *)
      echo "未知参数: $1" >&2
      exit 2
      ;;
  esac
done

for tool in readelf ldd; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "错误: 缺少 $tool（binutils / glibc）" >&2
    exit 2
  }
done

native="$bundle/native"
libdir="$bundle/lib"

# 系统库允许清单：仅 ABI 稳定、必须与系统共享的库。
# 新增第三方系统依赖时，先在 PR 里评估；能内嵌就内嵌，必须系统提供才加到这里。
readonly ALLOW_RE='^(ld-linux[^/]*\.so\..*|libc\.so\..*|libm\.so\..*|libpthread\.so\..*|libdl\.so\..*|librt\.so\..*|libresolv\.so\..*|libutil\.so\..*|libcrypt\.so\..*|libgcc_s\.so\..*|libstdc\+\+\.so\..*|libatomic\.so\..*|libgomp\.so\..*|libgtk-3\.so\..*|libgdk-3\.so\..*|libgdk_pixbuf-2\.0\.so\..*|libglib-2\.0\.so\..*|libgobject-2\.0\.so\..*|libgio-2\.0\.so\..*|libpango-1\.0\.so\..*|libpangocairo-1\.0\.so\..*|libcairo\.so\..*|libcairo-gobject\.so\..*|libharfbuzz\.so\..*|libatk-1\.0\.so\..*|libepoxy\.so\..*|libfontconfig\.so\..*|libfreetype\.so\..*|libz\.so\..*|libX11\.so\..*|libXext\.so\..*|libXi\.so\..*|libXfixes\.so\..*|libXrender\.so\..*|libxcb\.so\..*|libxkbcommon\.so\..*|libwayland-client\.so\..*|libwayland-cursor\.so\..*|libwayland-egl\.so\..*|libGL[^/]*\.so\..*|libEGL\.so\..*|libgbm\.so\..*|libdrm\.so\..*|libexpat\.so\..*|libpng16\.so\..*|libbrotli[^/]*\.so\..*|libgraphite2\.so\..*|libpixman-1\.so\..*|libthai\.so\..*|libdatrie\.so\..*|libfribidi\.so\..*|libffi\.so\..*|libpcre2-8\.so\..*|libuuid\.so\..*|libmount\.so\..*|libblkid\.so\..*|libselinux\.so\..*|libsystemd\.so\..*|libdbus-1\.so\..*|libcloudproviders\.so\..*|libsqlite3\.so\..*)$'

# 禁止项：OpenSSL 与 libcurl。scraper 的加密与 HTTP 都是内嵌 Rust 静态栈
# （AES/RSA + reqwest/rustls），产物不应再出现这些库的任何 DT_NEEDED。
readonly FORBID_RE='^(libssl|libcrypto|libcurl)\.so(\..*)?$'

errors=0
warnings=0
declare -a report_system=() report_bundled=()

fail() {
  echo "::error::$*" >&2
  errors=$((errors + 1))
}
warn() {
  echo "::warning::$*" >&2
  warnings=$((warnings + 1))
}

is_elf() { readelf -h "$1" >/dev/null 2>&1; }

# 关键发布文件（缺任意一个都说明打包链路断了）
require_file() {
  [[ -f "$1" ]] || fail "缺少发布必需文件：${1#"$bundle"/}"
}
require_file "$bundle/archoera_music"
require_file "$native/archoera-audio-engine"
require_file "$native/archoera-vault"
require_file "$native/libarchoera_mediaengine.so"
require_file "$native/libarchoera_scraper.so"
require_file "$native/scanner-ffi.so"
require_file "$native/indexer-ffi.so"
require_file "$native/libe_sqlite3.so"
[[ -f "$native/libarchoera_kernel.so" ]] || warn "缺 libarchoera_kernel.so（引擎将回退 FFmpeg/Stable）"

# NativeAOT 的 dlopen 依赖不在 DT_NEEDED 里，单独校验。
for consumer in scanner-ffi.so indexer-ffi.so; do
  [[ -f "$native/$consumer" ]] || continue
  [[ -f "$native/libe_sqlite3.so" ]] \
    || fail "$consumer 运行期需要 native/libe_sqlite3.so（dlopen，不在 DT_NEEDED）"
done

# 遍历 bundle 内全部 ELF（最多 3 层：根、native/、lib/）
mapfile -t elves < <(
  find "$bundle" -maxdepth 3 -type f -print0 |
    while IFS= read -r -d '' f; do
      is_elf "$f" && printf '%s\n' "$f"
    done
)

for f in "${elves[@]}"; do
  rel="${f#"$bundle"/}"

  # RUNPATH 只允许 $ORIGIN 相对路径
  while IFS= read -r rpath; do
    [[ -z "$rpath" ]] && continue
    IFS=':' read -r -a parts <<<"$rpath"
    for p in "${parts[@]}"; do
      [[ -z "$p" ]] && continue
      [[ "$p" == '$ORIGIN'* ]] \
        || fail "$rel: RUNPATH 含非 \$ORIGIN 路径：$p（bundle-linux-runtime.sh 未归一化？）"
    done
  done < <(readelf -d "$f" 2>/dev/null | sed -n 's/.*(\(RUNPATH\|RPATH\)).*\[\(.*\)\]/\2/p' || true)

  mapfile -t needed < <(
    readelf -d "$f" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' || true
  )
  [[ ${#needed[@]} -eq 0 ]] && continue

  # 显式清掉构建环境里的 LD_LIBRARY_PATH（CI 会把最小 FFmpeg 前缀放进去），
  # 让 ldd 完全按产物自身的 RUNPATH 解析，这样「内嵌库存在但 RUNPATH 丢失」
  # 会直接暴露，而不是被环境变量掩盖成构建机路径。
  ldd_out="$(env -u LD_LIBRARY_PATH -u LD_PRELOAD ldd "$f" 2>&1 || true)"
  if grep -q 'not found' <<<"$ldd_out"; then
    while IFS= read -r line; do
      fail "$rel: 依赖无法解析 → ${line#*$'\t'}"
    done < <(grep 'not found' <<<"$ldd_out")
  fi

  for n in "${needed[@]}"; do
    [[ -z "$n" ]] && continue

    if [[ "$n" =~ $FORBID_RE ]]; then
      fail "$rel: 禁止直接依赖 $n（OpenSSL/libcurl 不得直接链接/加载）"
      continue
    fi

    local_target=""
    for cand in "$(dirname "$f")/$n" "$native/$n" "$libdir/$n"; do
      if [[ -e "$cand" ]]; then
        local_target="$cand"
        break
      fi
    done
    resolved="$(awk -v n="$n" '$1==n && $2=="=>" {print $3; exit}' <<<"$ldd_out")"
    [[ "$resolved" == "not" ]] && resolved=""  # "=> not found" 已在上面的检查报错
    [[ -z "$resolved" ]] && continue            # 同上，避免重复报错

    if [[ -n "$local_target" ]]; then
      case "$resolved" in
        "$bundle"/*) ;;
        *)
          fail "$rel: 已内嵌 $n，但运行时解析到 ${resolved:-<未解析>}（\$ORIGIN 未生效？）"
          ;;
      esac
      soname="$(readelf -d "$local_target" 2>/dev/null |
        sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p' || true)"
      if [[ -n "$soname" && "$soname" != "$n" ]]; then
        fail "$rel: 内嵌 $n 的 SONAME=$soname，与需求名不一致"
      fi
      report_bundled+=("$n -> ${local_target#"$bundle"/}")
      continue
    fi

    allowed=0
    [[ "$n" =~ $ALLOW_RE ]] && allowed=1
    for pat in "${extra_allow[@]}"; do
      [[ "$n" == "$pat" ]] && allowed=1
    done
    if [[ $allowed -eq 0 ]]; then
      fail "$rel: 未登记的系统依赖 $n（能内嵌就内嵌；确需系统提供请加入允许清单）"
    else
      report_system+=("$n")
    fi
  done
done

# 去重 + 排序后写入报告（随包分发，便于用户/下游核对）
report="$bundle/ARCHOERA-DEPENDENCIES.txt"
{
  echo "# ArchoeraMusic 发布依赖清单（自动生成，勿手改）"
  echo "# bundle: $(basename "$bundle")"
  echo
  echo "[system] 由发行版提供（打包 depends / AppImage 自带）"
  printf '%s\n' "${report_system[@]}" | sort -u | sed '/^$/d'
  echo
  echo "[bundled] 随包内嵌（RUNPATH=\$ORIGIN）"
  printf '%s\n' "${report_bundled[@]}" | sort -u | sed '/^$/d'
  echo
  echo "[forbidden] libssl/libcrypto 直接依赖：$( [[ $errors -eq 0 ]] && echo none || echo 见 CI 日志 )"
} >"$report"

if [[ $errors -gt 0 ]]; then
  echo "依赖守卫失败：$errors 项错误、$warnings 项警告" >&2
  exit 1
fi

echo "依赖守卫通过：$(printf '%s\n' "${report_system[@]}" | sort -u | sed '/^$/d' | wc -l) 个系统库、" \
  "$(printf '%s\n' "${report_bundled[@]}" | sort -u | sed '/^$/d' | wc -l) 个内嵌库（报告: ${report#"$bundle"/}）"
if [[ $warnings -gt 0 ]]; then
  echo "（$warnings 项警告，见上）"
fi
exit 0
