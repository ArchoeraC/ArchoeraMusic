#!/usr/bin/env bash
# ArchoeraMusic scanner FFI 构建脚本（幂等）。
#
# 产物：scanner/build/{scanner-ffi.so, libe_sqlite3.so}
#   - scanner-ffi.so    ：.NET 9 NativeAOT 共享库（导出 scanner_scan/cancel/free）
#   - libe_sqlite3.so   ：SQLitePCLRaw 原生依赖（FFI 库运行所需，随包分发）
#
# 依赖：
#   - .NET 9 SDK（dotnet --version）
#   - NuGet 首次还原需网络（TagLibSharp/SQLitePCLRaw；可用国内镜像，见 nuget.config）
# 使用：./build.sh
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p build

dotnet publish scanner-ffi/scanner-ffi.csproj \
  -c Release \
  -r linux-x64

PUB=scanner-ffi/bin/Release/net9.0/linux-x64/publish
cp "$PUB/scanner-ffi.so" build/
cp "$PUB/libe_sqlite3.so" build/

echo "scanner FFI 产物就绪:"
ls -lh build/scanner-ffi.so build/libe_sqlite3.so
