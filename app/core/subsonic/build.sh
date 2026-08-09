#!/usr/bin/env bash
# 构建 Archoera Subsonic 服务端
#   1. cargo 构建 Rust 转码器 cdylib（libarchoera_transcoder.so）
#   2. go build -buildmode=c-shared 构建服务端库（libarchoera_subsonic.so，FFI）
#   3. go build -tags standalone 构建独立可执行（Docker/无宿主部署）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$ROOT/build"

echo "[subsonic] 构建转码器 (cargo cdylib)..."
(cd "$ROOT/transcoder" && cargo build --release)

echo "[subsonic] 构建服务端 (go c-shared)..."
(cd "$ROOT" && CGO_ENABLED=1 go build -buildmode=c-shared -o build/libarchoera_subsonic.so .)

echo "[subsonic] 构建独立可执行 (go -tags standalone)..."
(cd "$ROOT" && CGO_ENABLED=1 go build -tags standalone -o build/archoera-subsonic .)

echo "[subsonic] 复制转码器产物到 build/"
cp "$ROOT/transcoder/target/release/libarchoera_transcoder.so" "$ROOT/build/"

echo "[subsonic] 符号检查:"
nm -D "$ROOT/build/libarchoera_subsonic.so" | grep -E 'archoera_subsonic'
nm -D "$ROOT/build/libarchoera_transcoder.so" | grep -E 'archoera_transcode'
echo "[subsonic] 构建完成"
