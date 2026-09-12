#!/usr/bin/env bash
# =====================================================================
#  ArchoeraMusic 平台桥接 —— macOS 端本地交叉编译验证（Linux 主机）
#
#  在 Linux 上用系统 clang + macOS SDK 交叉编译并链接
#  libarchoera_platform.dylib（arm64 与 x86_64），确认 macOS 后端
#  （src/backend_macos.mm）可通过编译与链接。CI 仍在 macOS runner 原生
#  构建；本脚本仅用于本地快速验证，不改动仓库内产物。
#
#  SDK 查找顺序：
#    1. --sdk <path> 或环境变量 ARCHOERA_MACOS_SDK
#    2. ~/.local/share/macos-sdk/MacOSX14.0.sdk
#    3. ~/.local/share/macos-sdk/MacOSX*.sdk（取第一个）
#  缺失时用 --download 自动下载（默认 MacOSX14.0.sdk，约 67MB）。
#
#  依赖：clang++（支持 -target *-apple-macos*）、ld64.lld（LLVM lld）。
#
#  用法：
#    bash app/tool/verify_macos.sh                 # 已装 SDK：编译+链接 arm64+x86_64
#    bash app/tool/verify_macos.sh --download      # 缺 SDK 时先下载再验证
#    bash app/tool/verify_macos.sh --arch arm64    # 只验单个架构
#    ARCHOERA_MACOS_SDK=/path/MacOSX.sdk bash app/tool/verify_macos.sh
#
#  退出码：0 = 全部架构编译+链接成功；非 0 = 失败。
# =====================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PLATFORM_DIR="$ROOT/app/native/platform"

SDK_DIR_DEFAULT="$HOME/.local/share/macos-sdk"
SDK_VERSION="${ARCHOERA_MACOS_SDK_VERSION:-14.0}"
SDK_NAME="MacOSX${SDK_VERSION}.sdk"
SDK_MIRROR="${ARCHOERA_MACOS_SDK_URL:-https://github.com/joseluisq/macosx-sdks/releases/download/${SDK_VERSION}/${SDK_NAME}.tar.xz}"
MIN_MACOS="${ARCHOERA_MACOS_MIN:-14.0}"

CC="${CC:-clang++}"
ARCHS="arm64 x86_64"
SDK=""
DOWNLOAD=0

usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --download) DOWNLOAD=1; shift ;;
    --arch) ARCHS="$2"; shift 2 ;;
    --arch=*) ARCHS="${1#*=}"; shift ;;
    --sdk) SDK="$2"; shift 2 ;;
    --sdk=*) SDK="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1（-h 查看用法）" >&2; exit 2 ;;
  esac
done

if [ "$ARCHS" = "all" ]; then ARCHS="arm64 x86_64"; fi

# ── 定位 SDK ───────────────────────────────────────────────────────
if [ -z "$SDK" ] && [ -n "${ARCHOERA_MACOS_SDK:-}" ]; then SDK="$ARCHOERA_MACOS_SDK"; fi
if [ -z "$SDK" ] && [ -d "$SDK_DIR_DEFAULT/$SDK_NAME" ]; then SDK="$SDK_DIR_DEFAULT/$SDK_NAME"; fi
if [ -z "$SDK" ]; then
  SDK="$(find "$SDK_DIR_DEFAULT" -maxdepth 1 -iname 'MacOSX*.sdk' -type d 2>/dev/null | sort | tail -1 || true)"
fi

if [ -z "$SDK" ] || [ ! -d "$SDK" ]; then
  if [ "$DOWNLOAD" = "1" ]; then
    mkdir -p "$SDK_DIR_DEFAULT"
    echo "→ 下载 macOS SDK: $SDK_MIRROR"
    curl -fL --retry 3 -o "$SDK_DIR_DEFAULT/$SDK_NAME.tar.xz" "$SDK_MIRROR"
    echo "→ 解压到 $SDK_DIR_DEFAULT"
    tar -C "$SDK_DIR_DEFAULT" -xf "$SDK_DIR_DEFAULT/$SDK_NAME.tar.xz"
    rm -f "$SDK_DIR_DEFAULT/$SDK_NAME.tar.xz"
    SDK="$SDK_DIR_DEFAULT/$SDK_NAME"
  else
    cat >&2 <<EOF
找不到 macOS SDK。请任选其一：
  - 加 --download 自动下载（$SDK_MIRROR）
  - 手动下载解压到 $SDK_DIR_DEFAULT/
  - 用 --sdk <path> 或 ARCHOERA_MACOS_SDK=<path> 指定
（macOS SDK 为 Apple 许可，仅本地构建用途，勿入库。）
EOF
    exit 1
  fi
fi

# ── 工具链检查 ─────────────────────────────────────────────────────
command -v "$CC" >/dev/null 2>&1 || { echo "缺少编译器: $CC" >&2; exit 1; }
LD="${LD:-ld64.lld}"
command -v "$LD" >/dev/null 2>&1 || { echo "缺少链接器: $LD（LLVM lld）" >&2; exit 1; }

BUILD_DIR="${ARCHOERA_VERIFY_BUILD:-$(mktemp -d /tmp/archoera-macos-verify.XXXXXX)}"
mkdir -p "$BUILD_DIR"

echo "SDK   : $SDK"
echo "CC    : $($CC --version | head -1)"
echo "ARCHS : $ARCHS"
echo "OUT   : $BUILD_DIR"
echo

fail=0
for ARCH in $ARCHS; do
  TARGET="${ARCH}-apple-macos${MIN_MACOS}"
  echo "===== $TARGET ====="
  objs=()
  # core / apl（纯 C++）
  for f in core apl; do
    o="$BUILD_DIR/${ARCH}_${f}.o"
    if $CC -target "$TARGET" -isysroot "$SDK" -std=c++20 -O2 \
        -DARCHOERA_PLATFORM_BUILD \
        -I "$PLATFORM_DIR/include" -I "$PLATFORM_DIR/src" \
        -c "$PLATFORM_DIR/src/$f.cpp" -o "$o"; then
      objs+=("$o")
    else
      echo "  编译失败: $f.cpp"; fail=1
    fi
  done
  # backend_macos（ObjC++，需 ARC）
  o="$BUILD_DIR/${ARCH}_backend_macos.o"
  if $CC -target "$TARGET" -isysroot "$SDK" -fobjc-arc -std=c++20 -O2 \
      -DARCHOERA_PLATFORM_BUILD \
      -I "$PLATFORM_DIR/include" -I "$PLATFORM_DIR/src" \
      -c "$PLATFORM_DIR/src/backend_macos.mm" -o "$o"; then
    objs+=("$o")
  else
    echo "  编译失败: backend_macos.mm"; fail=1
  fi
  # 链接 dylib（与 CMake 的 macOS 链接项一致）
  dylib="$BUILD_DIR/libarchoera_platform_${ARCH}.dylib"
  if [ "$fail" = "0" ] && $CC -target "$TARGET" -isysroot "$SDK" \
      -fuse-ld=lld -dynamiclib \
      -framework Foundation -framework AppKit -framework MediaPlayer \
      -framework UserNotifications -framework CoreFoundation \
      "${objs[@]}" -o "$dylib"; then
    echo "  → OK  $(file -b "$dylib" | cut -d, -f1-2)"
  else
    echo "  链接失败"; fail=1
  fi
  echo
done

# 导出符号抽查（新增 ABI 是否在）
DYLIB_ONE="$(ls "$BUILD_DIR"/libarchoera_platform_*.dylib 2>/dev/null | head -1 || true)"
if [ -n "$DYLIB_ONE" ] && command -v llvm-nm >/dev/null 2>&1; then
  echo "===== 导出符号抽查（$DYLIB_ONE）====="
  llvm-nm --defined-only "$DYLIB_ONE" | grep -E '_apl_(system_theme_set_events|system_accent_set_events|window_set_events|abi_version)$' || true
  echo
fi

if [ "$fail" = "0" ]; then
  echo "✅ macOS 端编译+链接通过（$ARCHS）"
else
  echo "❌ macOS 端验证失败" >&2
fi
exit $fail
