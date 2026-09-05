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
  (cd "$ROOT/audio-engine" && zig build -Doptimize=ReleaseFast) || exit 1
else
  echo "[build-linux] 警告: 未检测到 zig，自研内核(EraAudio)不编译（引擎将以 FFmpeg/Stable 运行）；"
  echo "          安装 Zig 0.16（https://ziglang.org/download）后重跑可启用 EraAudio。"
fi

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

echo "[build-linux] 全部模块构建完成"
