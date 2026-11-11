#!/usr/bin/env bash
# =====================================================================
#  ArchoeraMusic macOS 全模块一站式构建脚本（对齐 build_windows.bat 模式）
#
#  在单个 bash 会话内完成全部原生模块编译（产物与 RID 单架构一致）：
#    1. audio-engine : CMake（FFmpeg 解码/EQ/FFT + Rust tempo）
#    2. scraper      : CMake（TagLib；加密与 HTTP 由内嵌 Rust staticlib 提供）
#    3. scanner      : dotnet publish (NativeAOT) + libe_sqlite3
#    4. indexer      : dotnet publish (NativeAOT, indexer-ffi) + libe_sqlite3
#    5. vault        : cargo build（vault-rs，Rust 凭据保险库，单架构）
#    6. downloader   : cargo build --release (cdylib)
#    7. subsonic     : cargo transcoder + go c-shared + go standalone
#    8. platform     : CMake（平台能力桥接 libarchoera_platform，app/native/platform）
#    9. shell        : cargo staticlib（内嵌原生 CLI archoerashell，链入 macOS Runner）
#
#  用法：build-macos.sh [osx-arm64|osx-x64]
#    - osx-arm64：Apple Silicon（默认）
#    - osx-x64  ：Intel；需在 Intel 主机或已准备 x86_64 Homebrew/FFmpeg 依赖的环境
#
#  依赖（Homebrew 自建 FFmpeg/taglib、CMake、Rust、Go、.NET）由 CI
#  workflow 提前安装或由本地开发环境提供，本脚本只做编译引导（幂等）。
#
#  注意：CMake 的 build/ 目录不区分架构；同一工作区切换 RID 前请清理各模块
#  build/，避免把上一架构的 .o/.a 混进新产物。
# =====================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS="$(sysctl -n hw.ncpu)"
RID="${1:-osx-arm64}"
HOST_ARCH="$(uname -m)"

case "$RID" in
  osx-arm64)
    TARGET_ARCH=arm64
    CMAKE_ARCH=arm64
    RUST_TARGET=aarch64-apple-darwin
    ZIG_KERNEL_TARGET="aarch64-macos.14.0"
    ;;
  osx-x64)
    TARGET_ARCH=x86_64
    CMAKE_ARCH=x86_64
    RUST_TARGET=x86_64-apple-darwin
    ZIG_KERNEL_TARGET="x86_64-macos.14.0"
    ;;
  *)
    echo "[build-macos] 错误: 未知 RID '$RID'（支持 osx-arm64 / osx-x64）" >&2
    exit 2
    ;;
esac

case "$RID:$HOST_ARCH" in
  osx-arm64:arm64|osx-x64:x86_64) ;;
  *)
    echo "[build-macos] 警告: RID=$RID 与当前主机 $HOST_ARCH 不一致；" >&2
    echo "[build-macos]       Homebrew / FFmpeg / opus 等依赖也必须是 $TARGET_ARCH，否则链接会失败。" >&2
    ;;
esac

# 统一 macOS 部署目标：Rust 默认按构建机 SDK 出包（CI 为 14.5），而
# CMake/clang 侧按 14.0 链接，混链会产生 "built for newer macOS version"
# 警告，且最终 dylib 的最低系统版本会被抬高到 14.5。此处显式对齐到
# 14.0（与 C 侧一致），cargo（tempo/downloader/transcoder）全部生效。
export MACOSX_DEPLOYMENT_TARGET=14.0

# Homebrew 前缀随架构变化：Apple Silicon 在 /opt/homebrew，Intel 在 /usr/local。
# opus 的 pkg-config 路径用于 FFmpeg --enable-libopus（本地构建时 CI 已预置最小
# FFmpeg 时也保留）。
BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
if [ -n "$BREW_PREFIX" ]; then
  export CMAKE_PREFIX_PATH="$BREW_PREFIX${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
  export PKG_CONFIG_PATH="$BREW_PREFIX/opt/opus/lib/pkgconfig:$BREW_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
else
  echo "[build-macos] 警告: 未检测到 Homebrew；scraper/audio-engine 需自行提供 taglib/opus 依赖。" >&2
fi

CMAKE_ARCH_ARGS=(-DCMAKE_OSX_ARCHITECTURES="$CMAKE_ARCH")


# 自研内核（EraAudio, Zig 静态库）须先于 audio-engine cmake 编译并落 zig-out/
# （engine CMake 复制 zig-out/lib/libarchoera_kernel.a 链接；kernel 改动后
#   必须重跑本步，否则陈旧产物会让 EraAudio 行为异常——见 docs/engine-integration-bench.md）
if command -v zig >/dev/null 2>&1; then
  echo "[build-macos] ===== audio-engine: zig kernel (ReleaseFast) ====="
  (cd "$ROOT/audio-engine" && zig build -Doptimize=ReleaseFast ${ZIG_KERNEL_TARGET:+-Dtarget=$ZIG_KERNEL_TARGET}) || exit 1
else
  echo "[build-macos] 警告: 未检测到 zig，自研内核(EraAudio)不编译（引擎将以 FFmpeg/Stable 运行）；"
  echo "          安装 Zig 0.17（https://ziglang.org/download）后重跑可启用 EraAudio。"
fi

echo "[build-macos] ===== audio-engine ($TARGET_ARCH) ====="
cmake -S "$ROOT/audio-engine" -B "$ROOT/audio-engine/build" \
  -DCMAKE_BUILD_TYPE=Release "${CMAKE_ARCH_ARGS[@]}"
cmake --build "$ROOT/audio-engine/build" -j"$JOBS"

echo "[build-macos] ===== scraper ($TARGET_ARCH) ====="
cmake -S "$ROOT/scraper" -B "$ROOT/scraper/build" \
  -DCMAKE_BUILD_TYPE=Release "${CMAKE_ARCH_ARGS[@]}"
cmake --build "$ROOT/scraper/build" -j"$JOBS"

echo "[build-macos] ===== scanner (NativeAOT, RID=$RID) ====="
bash "$ROOT/scanner/build.sh" "$RID"

# 本地曲库搜索索引器（indexer-ffi，.NET NativeAOT，与 scanner 同栈）：
# 产出 indexer/build/{indexer-ffi.dylib, libe_sqlite3.dylib}，由 Runner.xcodeproj
# 的 “Copy Native Modules” 阶段装进 .app/Contents/native/（总开关默认关时
# Dart 侧不加载，见 lib/services/search/）。
echo "[build-macos] ===== indexer (NativeAOT, RID=$RID) ====="
bash "$ROOT/indexer/build.sh" "$RID"

echo "[build-macos] ===== vault (Rust 静态链接, vault-rs, $TARGET_ARCH) ====="
# vault-rs：Rust 实现（OS 授权份额存 Keychain；容器格式由 testdata/ 黄金夹具锚定字节兼容）。
# 与 .app 同架构：单独构建 RUST_TARGET，避免向单架构包里塞 universal 可执行文件。
# Runner.xcodeproj 的拷贝阶段与 CI bundle 步骤均从 core/vault-rs/build/ 取。
# macOS 已不再使用 C# NativeAOT vault（app/core/vault/** 已于 2026-10-12 删除，
# 字节兼容改由 app/core/vault-rs/testdata/ 黄金夹具锚定）。
# 目标架构已由 CI（rustup target add）或本地 rustup 预装；此处幂等兜底。
rustup target add "$RUST_TARGET" >/dev/null 2>&1 || true
cargo build --release --manifest-path "$ROOT/vault-rs/Cargo.toml" --target "$RUST_TARGET"
mkdir -p "$ROOT/vault-rs/build"
install -m 755 "$ROOT/vault-rs/target/$RUST_TARGET/release/archoera-vault" \
  "$ROOT/vault-rs/build/archoera-vault"

echo "[build-macos] ===== downloader (Rust cdylib) ====="
cargo build --release --manifest-path "$ROOT/downloader/Cargo.toml"

echo "[build-macos] ===== subsonic (Go + Rust transcoder) ====="
bash "$ROOT/subsonic/build.sh"

# 平台能力桥接（SystemPower/SystemMedia/SystemWindow，apl_* C ABI，Dart FFI 直连）。
# CMake 构建（ObjC++ + AppKit/MediaPlayer/Foundation），产物落 build/out/。
echo "[build-macos] ===== platform bridge (CMake ObjC++, $TARGET_ARCH) ====="
cmake -S "$ROOT/../native/platform" -B "$ROOT/../native/platform/build" \
  -DCMAKE_BUILD_TYPE=Release "${CMAKE_ARCH_ARGS[@]}"
cmake --build "$ROOT/../native/platform/build" -j"$JOBS"

# 统一日志核心（libarchoera_log，C；Dart 载入后注入各原生层的 sink）。
echo "[build-macos] ===== log core (CMake C, $TARGET_ARCH) ====="
cmake -S "$ROOT/../native/log" -B "$ROOT/../native/log/build" \
  -DCMAKE_BUILD_TYPE=Release "${CMAKE_ARCH_ARGS[@]}"
cmake --build "$ROOT/../native/log/build" -j"$JOBS"

# 内嵌原生 CLI（archoerashell）：Rust staticlib，由 Runner.xcodeproj 的
# “Build archoerashell (cargo)” 阶段按 Xcode 的 ARCHS 链入 .app；此处预构建
# 一次（幂等），独立跑本脚本时也能得到宿主机架构的 libarchoera_shell.a。
echo "[build-macos] ===== shell (Rust staticlib, archoerashell, $TARGET_ARCH) ====="
cargo build --release --manifest-path "$ROOT/shell/Cargo.toml"

echo "[build-macos] 全部模块构建完成"
