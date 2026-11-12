#!/usr/bin/env bash
# =====================================================================
#  ArchoeraMusic Linux 发布脚本（**Linux 专用，自包含**）
#
#  规则（AGENTS.md「禁止脚本混合」）：
#    - 平台构建/装配/校验/打包只在本文件与 packaging/linux/ 内，不调用其它
#      平台的脚本，也不依赖 app/tool 下的检查脚本；
#    - 只用 Linux 工具：readelf / ldd / patchelf / file / Xvfb。
#
#  子命令：
#    build    原生模块（app/core/build-linux.sh）→ pub get → analyze → flutter build
#    prepare  收拢自包含运行库（RUNPATH=$ORIGIN）+ 许可文本 + 防伪公钥
#    guard    静态依赖守卫：NEEDED / $ORIGIN / 内嵌库实际解析位置 / SONAME /
#             libssl·libcrypto·libcurl 禁止项 / 伴随库；产出
#             ARCHOERA-DEPENDENCIES.txt
#    verify   guard + 关键伴随库在包内 + Xvfb 下真实启动冒烟（LD_BIND_NOW）
#    smoke-appimage  对最终 .AppImage 做启动冒烟（--appimage-extract-and-run，
#                    无需 FUSE）
#    all      build → prepare → verify（任一步失败即整体失败）
#
#  本脚本**不含任何测试**：flutter test / cargo test / ctest 等全部在本地按
#  AGENTS.md「提交前必跑」执行，CI 只做编译、守卫与打包。
#
#  用法：
#    bash packaging/linux/build-release.sh all
#    bash packaging/linux/build-release.sh guard  --bundle <目录>
#    bash packaging/linux/build-release.sh verify --bundle <目录>
#    bash packaging/linux/build-release.sh smoke-appimage --appimage <文件>
#    SKIP_BUILD=1 bash packaging/linux/build-release.sh all
#    ARCHOERA_SMOKE_SECONDS=15   启动冒烟存活秒数
#
#  退出码: 0 成功；1 检查/构建失败；2 用法错误或不在 Linux 上。
# =====================================================================
set -euo pipefail

if [ "$(uname -s)" != "Linux" ]; then
  echo "错误: 本脚本只能在 Linux 上运行（需要 readelf / ldd / patchelf / Xvfb）" >&2
  exit 2
fi

# packaging/linux/ → 仓库根
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUNDLE_DEFAULT="$ROOT/app/build/linux/x64/release/bundle"

# 系统库允许清单：仅 ABI 稳定、必须与系统共享的库（同时在打包 depends 声明）。
# 新增第三方系统依赖时先在 PR 里评估：能内嵌就内嵌，确需系统提供才加到这里。
readonly ALLOW_RE='^(ld-linux[^/]*\.so\..*|libc\.so\..*|libm\.so\..*|libpthread\.so\..*|libdl\.so\..*|librt\.so\..*|libresolv\.so\..*|libutil\.so\..*|libcrypt\.so\..*|libgcc_s\.so\..*|libstdc\+\+\.so\..*|libatomic\.so\..*|libgomp\.so\..*|libgtk-3\.so\..*|libgdk-3\.so\..*|libgdk_pixbuf-2\.0\.so\..*|libglib-2\.0\.so\..*|libgobject-2\.0\.so\..*|libgio-2\.0\.so\..*|libpango-1\.0\.so\..*|libpangocairo-1\.0\.so\..*|libcairo\.so\..*|libcairo-gobject\.so\..*|libharfbuzz\.so\..*|libatk-1\.0\.so\..*|libepoxy\.so\..*|libfontconfig\.so\..*|libfreetype\.so\..*|libz\.so\..*|libX11\.so\..*|libXext\.so\..*|libXi\.so\..*|libXfixes\.so\..*|libXrender\.so\..*|libxcb\.so\..*|libxkbcommon\.so\..*|libwayland-client\.so\..*|libwayland-cursor\.so\..*|libwayland-egl\.so\..*|libGL[^/]*\.so\..*|libEGL\.so\..*|libgbm\.so\..*|libdrm\.so\..*|libexpat\.so\..*|libpng16\.so\..*|libbrotli[^/]*\.so\..*|libgraphite2\.so\..*|libpixman-1\.so\..*|libthai\.so\..*|libdatrie\.so\..*|libfribidi\.so\..*|libffi\.so\..*|libpcre2-8\.so\..*|libuuid\.so\..*|libmount\.so\..*|libblkid\.so\..*|libselinux\.so\..*|libsystemd\.so\..*|libdbus-1\.so\..*|libcloudproviders\.so\..*|libsqlite3\.so\..*)$'

# 禁止项：OpenSSL 与 libcurl（scraper 的加密与 HTTP 均为内嵌 Rust 静态栈）。
readonly FORBID_RE='^(libssl|libcrypto|libcurl)\.so(\..*)?$'

usage() {
  sed -n '/^#  用法：/,/^#  退出码:/p' "${BASH_SOURCE[0]}" | sed 's/^#  \{0,2\}//'
  exit 2
}

log() { echo "[linux] $*"; }
die() { echo "::error::$*" >&2; exit 1; }

require_tools() {
  missing=""
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
  done
  [ -z "$missing" ] || die "缺少工具:$missing"
}

# ─────────────────────────── 参数 ───────────────────────────
step="${1:-}"
[ -n "$step" ] || usage
shift

bundle=""
appimage=""
allow_extra=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --bundle)
      [ "$#" -ge 2 ] || usage
      bundle="$2"
      shift 2
      ;;
    --appimage)
      [ "$#" -ge 2 ] || usage
      appimage="$2"
      shift 2
      ;;
    --allow-extra)
      [ "$#" -ge 2 ] || usage
      allow_extra+=("$2")
      shift 2
      ;;
    -h | --help) usage ;;
    *) echo "未知参数: $1" >&2 && usage ;;
  esac
done
[ -n "$bundle" ] || bundle="$BUNDLE_DEFAULT"

# ─────────────────────────── build ──────────────────────────
do_build() {
  log "build: 原生模块"
  bash "$ROOT/app/core/build-linux.sh"

  # 注意：这里**不得**加入任何测试（flutter test / cargo test / ctest）；
  # 测试只在本地执行，CI 只做编译与打包。
  log "build: flutter pub get / analyze / build linux"
  (
    cd "$ROOT/app"
    flutter pub get
    dart analyze lib
    flutter build linux --release
  )
}

# ────────────────────────── prepare ─────────────────────────
do_prepare() {
  require_tools patchelf readelf ldd file
  [ -d "$bundle" ] || die "找不到 bundle: $bundle"
  bundle="$(cd "$bundle" && pwd)"

  log "prepare: 收拢自包含运行库 + RUNPATH=\$ORIGIN"
  bash "$ROOT/app/core/bundle-linux-runtime.sh" "$bundle"

  log "prepare: LGPL 许可文本 + 聚合声明"
  bash "$ROOT/app/core/bundle-licenses.sh" "$bundle"

  log "prepare: 防伪公钥"
  cp "$ROOT/app/tool/watermark_pub.pem" "$bundle/ARCHOERA_PUBKEY.pem"

  # 完整性清单（SEC-08）：必须在收拢/改写之后生成
  sh "$ROOT/app/tool/gen_native_manifest.sh" "$bundle/native" "$bundle/archoera_music"
}

# ─────────────────────────── guard ──────────────────────────
# 逐 ELF 校验依赖闭包。任何错误 → 非零退出。
do_guard() {
  require_tools readelf ldd
  [ -d "$bundle" ] || die "找不到 bundle: $bundle"
  bundle="$(cd "$bundle" && pwd)"
  native="$bundle/native"
  libdir="$bundle/lib"

  errors=0
  warnings=0
  report_system=()
  report_bundled=()

  fail() {
    echo "::error::$*" >&2
    errors=$((errors + 1))
  }
  warn() {
    echo "::warning::$*" >&2
    warnings=$((warnings + 1))
  }
  is_elf() { readelf -h "$1" >/dev/null 2>&1; }
  require_file() { [ -f "$1" ] || fail "缺少发布必需文件：${1#"$bundle"/}"; }

  require_file "$bundle/archoera_music"
  require_file "$native/archoera-audio-engine"
  require_file "$native/archoera-vault"
  require_file "$native/libarchoera_mediaengine.so"
  require_file "$native/libarchoera_scraper.so"
  require_file "$native/scanner-ffi.so"
  require_file "$native/indexer-ffi.so"
  require_file "$native/libe_sqlite3.so"
  [ -f "$native/libarchoera_kernel.so" ] \
    || warn "缺 libarchoera_kernel.so（引擎将回退 FFmpeg/Stable）"

  # NativeAOT 的 dlopen 伴随库不在 DT_NEEDED 里，单独校验。
  for consumer in scanner-ffi.so indexer-ffi.so; do
    [ -f "$native/$consumer" ] || continue
    [ -f "$native/libe_sqlite3.so" ] \
      || fail "$consumer 运行期需要 native/libe_sqlite3.so（dlopen，不在 DT_NEEDED）"
  done

  elf_list="$(mktemp "${TMPDIR:-/tmp}/archoera-elf.XXXXXX")"
  trap 'rm -f "$elf_list"' EXIT
  find "$bundle" -maxdepth 3 -type f -print0 |
    while IFS= read -r -d '' f; do
      if is_elf "$f"; then
        printf '%s\n' "$f"
      fi
    done > "$elf_list"

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#"$bundle"/}"

    # RUNPATH 只允许 $ORIGIN 相对路径（防构建机绝对路径进产物）
    while IFS= read -r rpath; do
      [ -n "$rpath" ] || continue
      old_ifs="$IFS"
      IFS=':'
      set -- $rpath
      IFS="$old_ifs"
      for p in "$@"; do
        [ -n "$p" ] || continue
        case "$p" in
          '$ORIGIN'*) ;;
          *) fail "$rel: RUNPATH 含非 \$ORIGIN 路径：${p}（prepare 未归一化？）" ;;
        esac
      done
    done < <(readelf -d "$f" 2>/dev/null |
      sed -n 's/.*(\(RUNPATH\|RPATH\)).*\[\(.*\)\]/\2/p' || true)

    needed_list="$(mktemp "${TMPDIR:-/tmp}/archoera-needed.XXXXXX")"
    readelf -d "$f" 2>/dev/null |
      sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' > "$needed_list" || true
    if [ ! -s "$needed_list" ]; then
      rm -f "$needed_list"
      continue
    fi

    # 清掉构建环境继承的 LD_LIBRARY_PATH，让 ldd 完全按产物自身 RUNPATH 解析，
    # 「内嵌库存在但 RUNPATH 丢失」才会暴露，而不是被构建机路径掩盖。
    ldd_out="$(env -u LD_LIBRARY_PATH -u LD_PRELOAD ldd "$f" 2>&1 || true)"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      fail "$rel: 依赖无法解析 → $line"
    done < <(printf '%s\n' "$ldd_out" | grep 'not found' || true)

    while IFS= read -r n; do
      [ -n "$n" ] || continue

      if printf '%s' "$n" | grep -Eq "$FORBID_RE"; then
        fail "$rel: 禁止直接依赖 ${n}（OpenSSL/libcurl 不得直接链接/加载）"
        continue
      fi

      local_target=""
      for cand in "$(dirname "$f")/$n" "$native/$n" "$libdir/$n"; do
        if [ -e "$cand" ]; then
          local_target="$cand"
          break
        fi
      done
      resolved="$(printf '%s\n' "$ldd_out" |
        awk -v n="$n" '$1==n && $2=="=>" {print $3; exit}')"
      # 注意：不能写成 `[ ... ] && var=...`——set -e 下条件不成立会让整个
      # 脚本静默中止（bash 把该语句列表视为失败）。
      if [ "$resolved" = "not" ]; then
        resolved=""   # "=> not found" 已在上面报错
      fi
      if [ -z "$resolved" ]; then
        continue      # 同上，避免重复报错
      fi

      if [ -n "$local_target" ]; then
        case "$resolved" in
          "$bundle"/*) ;;
          *) fail "$rel: 已内嵌 ${n}，但运行时解析到 ${resolved:-<未解析>}（\$ORIGIN 未生效？）" ;;
        esac
        soname="$(readelf -d "$local_target" 2>/dev/null |
          sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p' || true)"
        if [ -n "$soname" ] && [ "$soname" != "$n" ]; then
          fail "$rel: 内嵌 $n 的 SONAME=${soname}，与需求名不一致"
        fi
        report_bundled+=("$n -> ${local_target#"$bundle"/}")
        continue
      fi

      allowed=0
      if printf '%s' "$n" | grep -Eq "$ALLOW_RE"; then allowed=1; fi
      for pat in ${allow_extra[@]+"${allow_extra[@]}"}; do
        if [ "$n" = "$pat" ]; then
          allowed=1
        fi
      done
      if [ "$allowed" -eq 0 ]; then
        fail "$rel: 未登记的系统依赖 ${n}（能内嵌就内嵌；确需系统提供请加入允许清单）"
      else
        report_system+=("$n")
      fi
    done < "$needed_list"
    rm -f "$needed_list"
  done < "$elf_list"

  report="$bundle/ARCHOERA-DEPENDENCIES.txt"
  {
    echo "# ArchoeraMusic 发布依赖清单（自动生成，勿手改）"
    echo "# bundle: $(basename "$bundle")"
    echo
    echo "[system] 由发行版提供（打包 depends / AppImage 自带）"
    printf '%s\n' ${report_system[@]+"${report_system[@]}"} | sort -u | sed '/^$/d'
    echo
    echo "[bundled] 随包内嵌（RUNPATH=\$ORIGIN）"
    printf '%s\n' ${report_bundled[@]+"${report_bundled[@]}"} | sort -u | sed '/^$/d'
    echo
    echo "[forbidden] libssl/libcrypto/libcurl 直接依赖：$([ "$errors" -eq 0 ] && echo none || echo 见构建日志)"
  } > "$report"

  if [ "$errors" -gt 0 ]; then
    echo "依赖守卫失败：$errors 项错误、$warnings 项警告" >&2
    exit 1
  fi
  log "依赖守卫通过：$(printf '%s\n' ${report_system[@]+"${report_system[@]}"} | sort -u | sed '/^$/d' | wc -l) 个系统库、" \
    "$(printf '%s\n' ${report_bundled[@]+"${report_bundled[@]}"} | sort -u | sed '/^$/d' | wc -l) 个内嵌库"
}

# ────────────────────────── 启动冒烟 ─────────────────────────
# Xvfb + 临时 HOME/XDG + LD_BIND_NOW 真实拉起发布包，存活 N 秒才算通过。
# smoke_run <可执行文件> [追加参数...]
smoke_run() {
  bin="$1"
  shift
  [ -x "$bin" ] || die "找不到可执行文件 $bin"
  require_tools timeout

  seconds="${ARCHOERA_SMOKE_SECONDS:-15}"
  case "$seconds" in
    '' | *[!0-9]*) die "ARCHOERA_SMOKE_SECONDS 必须是整数" ;;
  esac
  [ "$seconds" -ge 3 ] || die "ARCHOERA_SMOKE_SECONDS 必须 >= 3"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/archoera-smoke.XXXXXX")"
  cleanup() { rm -rf "$tmp"; }
  trap cleanup EXIT
  mkdir -p "$tmp/home" "$tmp/data" "$tmp/config" "$tmp/cache" "$tmp/run"
  chmod 700 "$tmp/run"

  # 隔离用户数据：只测启动，不碰真实曲库/凭据/偏好
  export HOME="$tmp/home"
  export XDG_DATA_HOME="$tmp/data"
  export XDG_CONFIG_HOME="$tmp/config"
  export XDG_CACHE_HOME="$tmp/cache"
  export XDG_RUNTIME_DIR="$tmp/run"
  export GDK_BACKEND=x11
  export LIBGL_ALWAYS_SOFTWARE=1
  export NO_AT_BRIDGE=1
  # 启动阶段立即解析全部动态符号
  export LD_BIND_NOW=1
  # 构建环境可能为最小 FFmpeg 设了 LD_LIBRARY_PATH；冒烟必须模拟用户机
  unset LD_LIBRARY_PATH LD_PRELOAD

  launch=()
  if [ -z "${DISPLAY:-}" ]; then
    command -v xvfb-run >/dev/null 2>&1 \
      || die "无 DISPLAY 且缺少 xvfb-run；请安装 xvfb"
    launch=(xvfb-run -a -s "-screen 0 1280x800x24")
  fi
  if command -v dbus-run-session >/dev/null 2>&1; then
    launch=(dbus-run-session -- ${launch[@]+"${launch[@]}"})
  fi

  logf="$tmp/app.log"
  set +e
  timeout --signal=TERM --kill-after=5s "${seconds}s" \
    ${launch[@]+"${launch[@]}"} "$bin" "$@" > "$logf" 2>&1
  rc=$?
  set -e

  loader_re='error while loading shared libraries|cannot open shared object file|undefined symbol|symbol lookup error|GLIBCXX_[0-9.]+.*not found|GLIBC_[0-9.]+.*not found'
  if grep -Eq "$loader_re" "$logf"; then
    echo "启动冒烟失败：动态加载/符号解析错误" >&2
    grep -E "$loader_re" "$logf" >&2 || true
    echo "--- 应用日志（尾部）---" >&2
    tail -80 "$logf" >&2
    exit 1
  fi

  # timeout 主动结束（124）或 TERM 后仍存活被 KILL（137）都说明进入事件循环
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    log "启动冒烟通过：$bin 在 ${seconds}s 内保持运行"
    return 0
  fi

  echo "启动冒烟失败：进程提前退出（rc=${rc}）" >&2
  echo "--- 应用日志（尾部）---" >&2
  tail -80 "$logf" >&2
  exit 1
}

# ─────────────────────────── verify ─────────────────────────
do_verify() {
  do_guard

  [ -d "$bundle" ] || die "找不到 bundle: $bundle"
  bundle="$(cd "$bundle" && pwd)"
  native="$bundle/native"

  log "verify: 关键伴随库在包内且计入完整性清单"
  for f in indexer-ffi.so scanner-ffi.so libe_sqlite3.so; do
    [ -f "$native/$f" ] || die "$f 未打入 Linux bundle"
  done
  grep -q 'indexer-ffi.so' "$native/ARCHOERA-NATIVE-MANIFEST.txt" \
    || die "完整性清单缺 indexer-ffi.so"

  smoke_run "$bundle/archoera_music"
}

# ──────────────────────────── 分发 ──────────────────────────
case "$step" in
  build) do_build ;;
  prepare) do_prepare ;;
  guard) do_guard ;;
  verify) do_verify ;;
  smoke-appimage)
    [ -n "$appimage" ] || usage
    [ -f "$appimage" ] || die "找不到 AppImage: $appimage"
    require_tools timeout
    log "smoke: AppImage（--appimage-extract-and-run）"
    smoke_run "$(cd "$(dirname "$appimage")" && pwd)/$(basename "$appimage")" \
      --appimage-extract-and-run
    ;;
  all)
    # 显式串行（不能用 `a; b; c` 分号序列：退出码会被最后一条命令覆盖）
    if [ "${SKIP_BUILD:-0}" = "1" ]; then
      log "SKIP_BUILD=1，跳过构建"
    else
      do_build
    fi
    do_prepare
    do_verify
    ;;
  *) usage ;;
esac
