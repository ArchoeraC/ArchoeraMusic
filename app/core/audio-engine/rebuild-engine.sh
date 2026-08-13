#!/usr/bin/env bash
# =====================================================================
#  即时自编译：用「系统 FFmpeg」重新构建音频引擎并替换 bundle 内嵌库。
#
#  背景：
#    bundle 默认内嵌构建机版本的 FFmpeg 运行库（自包含，系统 FFmpeg
#    升级不影响应用）。若你希望引擎跟随系统 FFmpeg（例如系统已是最新、
#    想省去内嵌库体积），或系统提示引擎库无法加载（内嵌库与较旧 glibc
#    系统不兼容等），可运行本脚本重建。
#
#  用法：
#    cd <bundle>/native && ./rebuild-engine.sh
#
#  前提（系统安装 FFmpeg 开发包 + 构建工具链）：
#    Debian/Ubuntu: sudo apt install build-essential cmake pkg-config cargo \
#        libavformat-dev libavcodec-dev libavutil-dev libswresample-dev
#    Arch/Manjaro:  sudo pacman -S base-devel cmake pkgconf cargo ffmpeg
#    Fedora/RHEL:   sudo dnf install gcc cmake pkgconfig cargo \
#        ffmpeg-devel
#
#  完成后面临两个选择：重启应用即用系统 FFmpeg 重建的引擎；恢复内嵌 =
#  重新解压官方发布包覆盖 native/（AUR 源码构建天然等效本脚本，无需手动）。
# =====================================================================
set -euo pipefail

NATIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$NATIVE_DIR/engine-src"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

[[ -d "$SRC_DIR" ]] || {
  echo "错误：未找到引擎源码 $SRC_DIR（bundle 未附带，请用官方发布包）" >&2
  exit 1
}

# 1) 系统 FFmpeg 开发库可用性（pkg-config）
for p in libavformat libavcodec libavutil libswresample; do
  if ! pkg-config --exists "$p"; then
    echo "错误：缺少系统 FFmpeg 开发库 $p（pkg-config 不可用）" >&2
    echo "  Debian/Ubuntu: sudo apt install libavformat-dev libavcodec-dev libavutil-dev libswresample-dev" >&2
    echo "  Arch/Manjaro:  sudo pacman -S ffmpeg" >&2
    echo "  Fedora/RHEL:   sudo dnf install ffmpeg-devel" >&2
    exit 1
  fi
done

echo "[rebuild-engine] 检测到系统 FFmpeg: $(pkg-config --modversion libavformat)"

# 2) 重编译引擎（独立工作目录，产物原子替换 native/；Rust tempo 不可用时
#    引擎降级编译——tempo 变速变调不可用，其余功能不受影响）
cmake -S "$SRC_DIR" -B "$WORK_DIR/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$WORK_DIR/build" -j"$(nproc)"

# 3) 替换引擎产物
install -m755 "$WORK_DIR/build/archoera-audio-engine" "$NATIVE_DIR/"
install -m755 "$WORK_DIR/build/libarchoera_mediaengine.so" "$NATIVE_DIR/"
install -m755 "$WORK_DIR/build/libfft.so" "$NATIVE_DIR/"

# 4) 以系统 FFmpeg 运行库替换内嵌库（引擎 RUNPATH=$ORIGIN 解析同目录）
for lib in libavformat libavcodec libavutil libswresample; do
  libdir="$(pkg-config --variable=libdir "$lib")"
  # shellcheck disable=SC2086  # 通配展开（.so.<ver> 实体；dev symlink 无需拷贝）
  install -m755 $libdir/${lib}.so.* "$NATIVE_DIR/"
done

echo "[rebuild-engine] 完成：引擎已用系统 FFmpeg 重建并替换，重启应用生效。"
echo "[rebuild-engine] 恢复内嵌：重新解压官方发布包覆盖 native/ 即可。"
