#!/usr/bin/env bash
# ArchoeraMusic scanner FFI 构建脚本（幂等）。
#
# 产物：scanner/build/{scanner-ffi.{so,dll,dylib}, libe_sqlite3.{so,dylib}, e_sqlite3.dll}
#   - scanner-ffi      ：.NET 10 NativeAOT 共享库（导出 scanner_scan/cancel/free）
#   - libe_sqlite3     ：SQLitePCLRaw 原生依赖（FFI 库运行所需，随包分发）
#     Windows 上无 lib 前缀（e_sqlite3.dll），与其他平台命名不同
#
# 依赖：
#   - .NET 10 SDK（dotnet --version）
#   - NuGet 首次还原需网络（TagLibSharp/SQLitePCLRaw；可用国内镜像，见 nuget.config）
# 使用：./build.sh [RID]     # RID 默认 linux-x64；三端：linux-x64 / win-x64 / osx-x64（或 osx-arm64）
set -euo pipefail
cd "$(dirname "$0")"

RID="${1:-linux-x64}"
case "$RID" in
  *win*) EXT="dll";  SQLITE_NAME="e_sqlite3.dll" ;;      # SQLitePCLRaw win-x64 bundle 无 lib 前缀
  *osx*) EXT="dylib"; SQLITE_NAME="libe_sqlite3.dylib" ;;
  *) EXT="so"; SQLITE_NAME="libe_sqlite3.so" ;;
esac

mkdir -p build

# 用 -o 固定 publish 输出目录（不依赖 bin/Release/<tfm>/<rid> 路径，
# Windows 的 AOT 输出还带 x64 前缀，随 TFM 升级会漂移）。
dotnet publish scanner-ffi/scanner-ffi.csproj \
  -c Release \
  -r "$RID" \
  -o build/publish

cp "build/publish/scanner-ffi.$EXT" build/
cp "build/publish/$SQLITE_NAME" "build/$SQLITE_NAME"

echo "scanner FFI 产物就绪:"
ls -lh "build/scanner-ffi.$EXT" "build/$SQLITE_NAME"
