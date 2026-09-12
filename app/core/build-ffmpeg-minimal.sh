#!/usr/bin/env bash
# =====================================================================
#  构建「最小自包含 · 纯 LGPL」FFmpeg（Linux / macOS）。
#
#  目的（两条）：
#   1. 自包含：发行版自带的 FFmpeg 链接大量外部视频/图像库（libx264/x265/
#      vpx/aom/SvtAv1/rav1e/jxl/librsvg→libicudata …），内嵌闭包 +236MB，
#      而音乐播放用不到；Homebrew 的 ffmpeg 同理。自建最小版只依赖
#      libc/libm/libz，内嵌约 10MB，soname 固定，不受系统版本影响。
#   2. 许可证：本项目 AGPL-3.0，THIRD-PARTY-LICENSES 明确要求 FFmpeg 为
#      **纯 LGPL 构建**（CONFIG_GPL=0 / CONFIG_NONFREE=0）且仅动态链接。
#      Homebrew ffmpeg 默认 --enable-gpl（GPL-3.0），会破坏该「GPL 防火墙」；
#      这里显式 --disable-gpl --disable-nonfree，保持 LGPL-2.1+。
#
#  环境变量：
#    FFMPEG_VERSION  源码版本（默认 7.1.1）
#    FFMPEG_PREFIX   安装前缀（默认 $HOME/.local/ffmpeg-minimal）
#  用法: build-ffmpeg-minimal.sh
# =====================================================================
set -euo pipefail

VER="${FFMPEG_VERSION:-7.1.1}"
PREFIX="${FFMPEG_PREFIX:-$HOME/.local/ffmpeg-minimal}"
if command -v nproc >/dev/null 2>&1; then JOBS="$(nproc)"; else JOBS="$(sysctl -n hw.ncpu)"; fi

if [[ -f "$PREFIX/lib/libavformat.so" || -f "$PREFIX/lib/libavformat.dylib" ]]; then
  echo "[build-ffmpeg-minimal] 已存在，跳过：$PREFIX"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "[build-ffmpeg-minimal] 下载 FFmpeg $VER 源码…"
curl -fsSL "https://ffmpeg.org/releases/ffmpeg-$VER.tar.xz" -o "$work/ffmpeg.tar.xz"
tar -C "$work" -xf "$work/ffmpeg.tar.xz"
cd "$work/ffmpeg-$VER"

# 有 nasm/yasm 则启用 x86 汇编加速；否则退化（仍可正常解码）
x86asm=()
if ! command -v nasm >/dev/null 2>&1 && ! command -v yasm >/dev/null 2>&1; then
  echo "[build-ffmpeg-minimal] 未找到 nasm/yasm → --disable-x86asm（性能降级，功能不受影响）"
  x86asm=(--disable-x86asm)
fi

# 共享库 RUNPATH：Linux 用 $ORIGIN；macOS 用 @loader_path（同目录解析）
if [[ "$(uname -s)" == "Darwin" ]]; then
  extra_ldflags="-Wl,-rpath,@loader_path"
else
  extra_ldflags="-Wl,-z,origin -Wl,-rpath,\$ORIGIN"
fi

echo "[build-ffmpeg-minimal] configure（纯 LGPL · 内部编解码器 · 共享库）…"
# --disable-autodetect：关闭所有外部库自动探测（zlib 除外，显式开启）
# --disable-gpl/nonfree：显式声明。注意 FFmpeg **没有** --enable-lgpl 选项：
#   LGPL-2.1+ 本就是默认（仅 --enable-gpl 会转 GPL，--enable-version3 会升
#   LGPLv3/GPLv3）。此配置产出 license="LGPL version 2.1 or later"
#   （可用 avutil_license() 验证），满足 AGPL-3.0 聚合分发的「GPL 防火墙」。
# --disable-programs   ：不出 ffmpeg/ffprobe 可执行文件，只出库
./configure \
  --prefix="$PREFIX" \
  --disable-autodetect \
  --enable-zlib \
  --disable-gpl \
  --disable-nonfree \
  --disable-programs \
  --disable-doc \
  --disable-static \
  --enable-shared \
  "${x86asm[@]}" \
  --extra-ldflags="$extra_ldflags"

echo "[build-ffmpeg-minimal] make -j$JOBS …"
make -j"$JOBS"
make install

# LGPL 合规：随库附上 FFmpeg 许可文本（打包时一并分发）
mkdir -p "$PREFIX/share/licenses/ffmpeg"
cp -f COPYING.LGPLv2.1 "$PREFIX/share/licenses/ffmpeg/" 2>/dev/null || true
cp -f LICENSE.md "$PREFIX/share/licenses/ffmpeg/" 2>/dev/null || true
{
  echo "FFmpeg $VER — 纯 LGPL 构建（--disable-gpl --disable-nonfree --disable-autodetect）"
  echo "源码：https://ffmpeg.org/releases/ffmpeg-$VER.tar.xz"
} > "$PREFIX/share/licenses/ffmpeg/BUILD-CONFIG.txt"

echo "[build-ffmpeg-minimal] 安装完成：$PREFIX"
ls -1 "$PREFIX/lib"/libav*.so* "$PREFIX/lib"/libswresample.so* 2>/dev/null \
  || ls -1 "$PREFIX/lib"/libav*.dylib "$PREFIX/lib"/libswresample*.dylib 2>/dev/null || true
