#!/usr/bin/env bash
# =====================================================================
#  ArchoeraMusic Linux 全模块一站式构建脚本（对齐 build_windows.bat 模式）
#
#  在单个 bash 会话内完成全部原生模块编译：
#    1. audio-engine : CMake（FFmpeg 解码/EQ/FFT + Rust tempo）
#    2. scraper      : CMake（C++ 元数据刮削）
#    3. scanner      : dotnet publish (NativeAOT) + libe_sqlite3
#    4. vault        : dotnet publish (NativeAOT 凭据保险库)
#    5. downloader   : cargo build --release (cdylib)
#    6. subsonic     : cargo transcoder + go c-shared + go standalone
#    7. platform     : CMake（平台能力桥接 libarchoera_platform，app/native/platform）
#
#  依赖（FFmpeg 开发包 / CMake / Rust / Go / .NET / Clang）由 CI workflow
#  提前安装或由本地开发环境提供，本脚本只做编译引导（幂等，可重复执行）。
#  产物布局与各模块 build/ 目录 + bundle/native/ 平铺安装引用对齐。
# =====================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS="$(nproc)"


# 自研内核（EraAudio, Zig 静态库）须先于 audio-engine cmake 编译并落 zig-out/
# （engine CMake 复制 zig-out/lib/libarchoera_kernel.a 链接；kernel 改动后
#   必须重跑本步，否则陈旧产物会让 EraAudio 行为异常——见 docs/engine-integration-bench.md）
if command -v zig >/dev/null 2>&1; then
  echo "[build-linux] ===== audio-engine: zig kernel (ReleaseFast) ====="
  # -Dcpu=baseline：内核必须按 x86-64 基线指令集编译。否则 Zig 默认按**构建机
  # 原生 CPU**（CI runner 常带 AVX-512）生成 EVEX/AVX512VL 指令，在普通用户
  # CPU（如 Raptor Lake，无 AVX-512）上直接 SIGILL（非法指令）。
  (cd "$ROOT/audio-engine" && zig build -Doptimize=ReleaseFast -Dcpu=baseline) || exit 1
else
  echo "[build-linux] 警告: 未检测到 zig，自研内核(EraAudio)不编译（引擎将以 FFmpeg/Stable 运行）；"
  echo "          安装 Zig 0.16（https://ziglang.org/download）后重跑可启用 EraAudio。"
fi

# ── FFmpeg：使用自建「最小纯 LGPL·仅音频」版本（与 CI 一致）──────────
# 未构建则先构建，并把 pkg-config / 运行时库路径指过去，确保引擎链接内嵌的
# 最小 FFmpeg 而非系统 FFmpeg。系统 FFmpeg 链接整套视频/图像库（libx264/
# x265/vpx/aom/jxl/rsvg/icu…），bundle-linux-runtime.sh 会把其依赖闭包整体
# 内嵌进 native/（实测 +126MB，deb 膨胀到数百 MB），必须避免。
FFMPEG_PREFIX="${FFMPEG_PREFIX:-$HOME/.local/ffmpeg-minimal}"
if [[ ! -f "$FFMPEG_PREFIX/lib/libavformat.so" ]]; then
  echo "[build-linux] ===== 构建最小 FFmpeg（纯 LGPL·仅音频）====="
  bash "$ROOT/build-ffmpeg-minimal.sh"
fi
export PKG_CONFIG_PATH="$FFMPEG_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LD_LIBRARY_PATH="$FFMPEG_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
echo "[build-linux] 使用自建 FFmpeg: $FFMPEG_PREFIX"

echo "[build-linux] ===== audio-engine ====="
cmake -S "$ROOT/audio-engine" -B "$ROOT/audio-engine/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$ROOT/audio-engine/build" -j"$JOBS"

echo "[build-linux] ===== scraper ====="
cmake -S "$ROOT/scraper" -B "$ROOT/scraper/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$ROOT/scraper/build" -j"$JOBS"

echo "[build-linux] ===== scanner (NativeAOT) ====="
bash "$ROOT/scanner/build.sh" linux-x64

echo "[build-linux] ===== vault (NativeAOT 凭据保险库) ====="
bash "$ROOT/vault/build.sh" linux-x64

echo "[build-linux] ===== downloader (Rust cdylib) ====="
cargo build --release --manifest-path "$ROOT/downloader/Cargo.toml"

echo "[build-linux] ===== subsonic (Go + Rust transcoder) ====="
bash "$ROOT/subsonic/build.sh"

# 平台能力桥接（SystemPower/SystemMedia/SystemWindow，apl_* C ABI，Dart FFI 直连；
# 见 docs/platform-native-bridge.md）。CMake 构建（C++ + libdbus + dlopen GTK）。
echo "[build-linux] ===== platform bridge (CMake C++) ====="
cmake -S "$ROOT/../native/platform" -B "$ROOT/../native/platform/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$ROOT/../native/platform/build" -j"$JOBS"

echo "[build-linux] 全部模块构建完成"
