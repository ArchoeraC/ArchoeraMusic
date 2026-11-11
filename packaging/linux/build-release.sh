#!/usr/bin/env bash
# =====================================================================
#  ArchoeraMusic Linux 发布脚本（**Linux 专用**）
#
#  设计原则（见 AGENTS.md「禁止脚本混合」）：Linux 的构建/自包含/守卫/打包只
#  走本文件与 packaging/linux/*，不与其他平台脚本互相调用；这里只使用 Linux
#  工具（readelf / ldd / patchelf / Xvfb）。
#
#  步骤：
#    build    原生模块（app/core/build-linux.sh）→ pub get → dart analyze → Flutter Release
#    check    只跑 dart analyze（本地快速复核用）
#    prepare  自包含运行库（bundle-linux-runtime.sh）+ 公钥 + 许可文本
#    verify   依赖守卫（check_bundle_deps.sh）+ 关键伴随库 + Xvfb 启动冒烟
#    all      build → prepare → verify（**任一步失败即整体失败**）
#
#  **本脚本不含任何测试**：flutter test / cargo test / ctest / go test /
#  dotnet test 一律只在本地按 AGENTS.md「提交前必跑」执行（CI 只做编译与打包）。
#  dart analyze 是编译级静态检查（非测试），与其它平台 job 保持一致保留。
#
#  用法：
#    bash packaging/linux/build-release.sh all
#    bash packaging/linux/build-release.sh check                # 只跑 analyze
#    bash packaging/linux/build-release.sh verify --bundle <路径>
#    SKIP_BUILD=1 bash packaging/linux/build-release.sh all     # 只重跑 prepare/verify
#    ARCHOERA_SMOKE_SECONDS=15   # 启动冒烟存活秒数
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

usage() {
  sed -n '/^#  用法：/,/^#  退出码:/p' "${BASH_SOURCE[0]}" | sed 's/^#  \{0,2\}//'
  exit 2
}

step="${1:-}"
[ -n "$step" ] || usage
shift

bundle=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --bundle)
      [ "$#" -ge 2 ] || usage
      bundle="$2"
      shift 2
      ;;
    -h | --help) usage ;;
    *) echo "未知参数: $1" >&2 && usage ;;
  esac
done
[ -n "$bundle" ] || bundle="$BUNDLE_DEFAULT"

log() { echo "[linux] $*"; }
die() { echo "::error::$*" >&2; exit 1; }

require_tools() {
  missing=""
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
  done
  [ -z "$missing" ] || die "缺少工具:$missing"
}

# ───────────────────────────── build ─────────────────────────────
do_build() {
  log "build: 原生模块"
  bash "$ROOT/app/core/build-linux.sh"

  # 注意：这里**不得**加入 flutter test / cargo test / ctest 等测试步骤
  # （测试全部在本地跑，CI 只做编译与打包）。
  log "build: flutter pub get / analyze / build linux（无测试）"
  (
    cd "$ROOT/app"
    flutter pub get
    dart analyze lib
    flutter build linux --release
  )
}

# 本地静态检查：CI 不调用（只用编译门禁），见文件头说明。
do_check() {
  log "check: dart analyze lib（本地门禁）"
  (cd "$ROOT/app" && dart analyze lib)
}

# ──────────────────────────── prepare ────────────────────────────
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
}

# ──────────────────────────── verify ─────────────────────────────
do_verify() {
  require_tools readelf ldd file
  [ -d "$bundle" ] || die "找不到 bundle: $bundle"
  bundle="$(cd "$bundle" && pwd)"

  log "verify: 依赖守卫（NEEDED / \$ORIGIN / 内嵌库解析位置 / libssl·libcurl 禁止项）"
  bash "$ROOT/app/tool/check_bundle_deps.sh" "$bundle"

  # 关键伴随库：NativeAOT 的 indexer/scanner 按名 dlopen libe_sqlite3，
  # 且必须计入完整性清单（SEC-08）。
  log "verify: indexer/scanner 伴随库在包内"
  native="$bundle/native"
  for f in indexer-ffi.so scanner-ffi.so libe_sqlite3.so; do
    [ -f "$native/$f" ] || die "$f 未打入 Linux bundle"
  done
  grep -q 'indexer-ffi.so' "$native/ARCHOERA-NATIVE-MANIFEST.txt" \
    || die "完整性清单缺 indexer-ffi.so"

  # 启动冒烟：Xvfb + 临时 HOME/XDG，LD_BIND_NOW 下真实拉起
  log "verify: Xvfb 启动冒烟"
  ARCHOERA_SMOKE_SECONDS="${ARCHOERA_SMOKE_SECONDS:-15}" \
    bash "$ROOT/app/tool/smoke_start_linux.sh" "$bundle"

  log "verify 完成"
}

case "$step" in
  build) do_build ;;
  check) do_check ;;
  prepare) do_prepare ;;
  verify) do_verify ;;
  all)
    # 显式串行：不能用 `a; b; c` 分号序列（退出码会被最后一条命令覆盖）
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
