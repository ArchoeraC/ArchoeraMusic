#!/usr/bin/env bash
# =====================================================================
#  ArchoeraMusic macOS 全模块一站式构建脚本（对齐 build_windows.bat 模式）
#
#  在单个 bash 会话内完成全部原生模块编译（arm64 默认，Intel 机器改
#   SCANNER/VAULT RID 传 osx-x64）：
#    1. audio-engine : CMake（FFmpeg 解码/EQ/FFT + Rust tempo）
#    2. scraper      : CMake（openssl keg-only 需 CMAKE_PREFIX_PATH）
#    3. scanner      : dotnet publish (NativeAOT) + libe_sqlite3
#    4. vault        : dotnet publish (NativeAOT 凭据保险库)
#    5. downloader   : cargo build --release (cdylib)
#    6. subsonic     : cargo transcoder + go c-shared + go standalone
#    7. platform     : CMake（平台能力桥接 libarchoera_platform，app/native/platform）
#
#  依赖（Homebrew FFmpeg/taglib/openssl、CMake、Rust、Go、.NET）由 CI
#  workflow 提前安装或由本地开发环境提供，本脚本只做编译引导（幂等）。
# =====================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS="$(sysctl -n hw.ncpu)"
RID="${1:-osx-arm64}"

# 统一 macOS 部署目标：Rust 默认按构建机 SDK 出包（CI 为 14.5），而
# CMake/clang 侧按 14.0 链接，混链会产生 "built for newer macOS version"
# 警告，且最终 dylib 的最低系统版本会被抬高到 14.5。此处显式对齐到
# 14.0（与 C 侧一致），cargo（tempo/downloader/transcoder）全部生效。
export MACOSX_DEPLOYMENT_TARGET=14.0

# Zig 内核同样对齐 14.0：Zig 默认按构建机 SDK 的 min-version 编静态库，会导致
# 链接期报 "object file ... was built for newer 'macOS' version (15.x) than being
# linked (14.0)"。按 RID 显式传含 min-version 的 target。
case "$RID" in
  osx-arm64) ZIG_KERNEL_TARGET="aarch64-macos.14.0" ;;
  osx-x64)   ZIG_KERNEL_TARGET="x86_64-macos.14.0" ;;
  *)         ZIG_KERNEL_TARGET="" ;;
esac


# 自研内核（EraAudio, Zig 静态库）须先于 audio-engine cmake 编译并落 zig-out/
# （engine CMake 复制 zig-out/lib/libarchoera_kernel.a 链接；kernel 改动后
#   必须重跑本步，否则陈旧产物会让 EraAudio 行为异常——见 docs/engine-integration-bench.md）
if command -v zig >/dev/null 2>&1; then
  echo "[build-macos] ===== audio-engine: zig kernel (ReleaseFast) ====="
  (cd "$ROOT/audio-engine" && zig build -Doptimize=ReleaseFast ${ZIG_KERNEL_TARGET:+-Dtarget=$ZIG_KERNEL_TARGET}) || exit 1
else
  echo "[build-macos] 警告: 未检测到 zig，自研内核(EraAudio)不编译（引擎将以 FFmpeg/Stable 运行）；"
  echo "          安装 Zig 0.16（https://ziglang.org/download）后重跑可启用 EraAudio。"
fi

echo "[build-macos] ===== audio-engine ====="
cmake -S "$ROOT/audio-engine" -B "$ROOT/audio-engine/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$ROOT/audio-engine/build" -j"$JOBS"

echo "[build-macos] ===== scraper (openssl keg-only) ====="
export CMAKE_PREFIX_PATH="/opt/homebrew/opt/openssl"
cmake -S "$ROOT/scraper" -B "$ROOT/scraper/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$ROOT/scraper/build" -j"$JOBS"

echo "[build-macos] ===== scanner (NativeAOT, RID=$RID) ====="
bash "$ROOT/scanner/build.sh" "$RID"

echo "[build-macos] ===== vault (NativeAOT 凭据保险库, RID=$RID) ====="
# macOS NativeAOT Swift 库链接（dotnet/runtime#125858）：.NET 10 的
# System.Security.Cryptography.Native.Apple 含 Swift 编译的 pal_swiftbindings.o，
# 其 __swift_FORCE_LOAD_$_swift_* 符号依赖系统 Swift 运行时库。根因是 .NET 10
# 默认部署目标 AppleMinOSVersion=12.0，而 macOS-14/15 runner 的 /usr/lib/swift
# 库 minOS≥13 被 ld_classic 按版本拒绝；修复在 csproj 内覆盖 AppleMinOSVersion=14.0。
# 此处再注入两个候选库目录兜底（SDK 的 .tbd stub + toolchain 的 macosx 目录），
# 由 csproj 项目级 LinkerArg 消费（静态求值，必生效）。
export SDKROOT="$(xcrun --show-sdk-path)"
export SWIFT_TOOLCHAIN_LIB="$(dirname "$(dirname "$(xcrun -f swift)")")/lib/swift/macosx"
bash "$ROOT/vault/build.sh" "$RID"

echo "[build-macos] ===== downloader (Rust cdylib) ====="
cargo build --release --manifest-path "$ROOT/downloader/Cargo.toml"

echo "[build-macos] ===== subsonic (Go + Rust transcoder) ====="
bash "$ROOT/subsonic/build.sh"

# 平台能力桥接（SystemPower/SystemMedia/SystemWindow，apl_* C ABI，Dart FFI 直连）。
# CMake 构建（ObjC++ + AppKit/MediaPlayer/Foundation），产物落 build/out/。
echo "[build-macos] ===== platform bridge (CMake ObjC++) ====="
cmake -S "$ROOT/../native/platform" -B "$ROOT/../native/platform/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$ROOT/../native/platform/build" -j"$JOBS"

echo "[build-macos] 全部模块构建完成"
