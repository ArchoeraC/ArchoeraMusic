#!/usr/bin/env bash
# 构建 Archoera Subsonic 服务端
#   1. cargo 构建 Rust 转码器 cdylib（libarchoera_transcoder.{so,dylib,dll}）
#   2. go build -buildmode=c-shared 构建服务端库（libarchoera_subsonic.{so,dylib,dll}，FFI）
#   3. go build -tags standalone 构建独立可执行（Docker/无宿主部署）
# 三端通用：Linux .so / macOS .dylib / Windows(Git Bash) .dll
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$ROOT/build"

case "$(uname -s)" in
  Darwin*) EXT="dylib" ;;
  MINGW*|MSYS*|CYGWIN*) EXT="dll" ;;
  *) EXT="so" ;;
esac

echo "[subsonic] 构建转码器 (cargo cdylib)..."
(cd "$ROOT/transcoder" && cargo build --release)

echo "[subsonic] 构建服务端 (go c-shared)..."
(cd "$ROOT" && CGO_ENABLED=1 go build -buildmode=c-shared -o "build/libarchoera_subsonic.$EXT" .)

echo "[subsonic] 构建独立可执行 (go -tags standalone)..."
(cd "$ROOT" && CGO_ENABLED=1 go build -tags standalone -o "build/archoera-subsonic" .)

echo "[subsonic] 复制转码器产物到 build/（Windows 下 cdylib 无 lib 前缀）"
TRANSCODER_SRC="$ROOT/transcoder/target/release/libarchoera_transcoder.$EXT"
if [ ! -f "$TRANSCODER_SRC" ]; then
  TRANSCODER_SRC="$ROOT/transcoder/target/release/archoera_transcoder.$EXT"
fi
cp "$TRANSCODER_SRC" "$ROOT/build/"

echo "[subsonic] 符号检查:"
nm -D "$ROOT/build/libarchoera_subsonic.$EXT" | grep -E 'archoera_subsonic' || true
nm -D "$ROOT/build/libarchoera_transcoder.$EXT" | grep -E 'archoera_transcode' || true
echo "[subsonic] 构建完成"
