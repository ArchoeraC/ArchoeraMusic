#!/usr/bin/env bash
# ArchoeraMusic 本地曲库搜索索引器构建脚本（幂等）。
#
# 产物：indexer/build/{indexer-ffi.{so,dll,dylib}, libe_sqlite3.{so,dylib}, e_sqlite3.dll}
#   - indexer-ffi  ：.NET 10 NativeAOT 共享库（导出 indexer_run/cancel/free/analyze/set_log_sink）
#   - libe_sqlite3 ：SQLitePCLRaw 原生依赖（含 FTS5；FFI 库运行所需，随包分发）
#     Windows 上无 lib 前缀（e_sqlite3.dll），与其他平台命名不同
#
# 依赖：
#   - .NET 10 SDK（dotnet --version）
#   - python3（仅当 data/*.tsv 缺失时离线生成；联网无关）
#   - NuGet 首次还原需网络（Microsoft.Data.Sqlite / SQLitePCLRaw，与 scanner 同版本）
# 使用：./build.sh [RID]     # RID 默认 linux-x64；三端：linux-x64 / win-x64 / osx-x64（或 osx-arm64）
set -euo pipefail
cd "$(dirname "$0")"

RID="${1:-linux-x64}"
case "$RID" in
  *win*) EXT="dll";   SQLITE_NAME="e_sqlite3.dll" ;;
  *osx*) EXT="dylib"; SQLITE_NAME="libe_sqlite3.dylib" ;;
  *)     EXT="so";    SQLITE_NAME="libe_sqlite3.so" ;;
esac

mkdir -p build

# 分析器数据表（逐字符 NFKC 兼容折叠）：缺失时离线生成（幂等）。
# 拼音/繁简/全角由 ToolGood.Words（NuGet）提供，GB18030 由框架 CodePages 提供，无需生成。
if [ ! -f data/nfkc.tsv ]; then
  echo "==> 生成 Unicode 兼容折叠表 (data/nfkc.tsv)"
  python3 tools/gen_hanzi_data.py
fi

# 用 -o 固定 publish 输出目录（不依赖 bin/Release/<tfm>/<rid> 路径）
echo "==> 发布 indexer FFI (NativeAOT, $RID)"
dotnet publish indexer-ffi/indexer-ffi.csproj \
  -c Release \
  -r "$RID" \
  -o build/publish

cp "build/publish/indexer-ffi.$EXT" build/
cp "build/publish/$SQLITE_NAME" "build/$SQLITE_NAME"

echo "indexer FFI 产物就绪:"
ls -lh "build/indexer-ffi.$EXT" "build/$SQLITE_NAME"
