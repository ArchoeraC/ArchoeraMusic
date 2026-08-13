#!/usr/bin/env bash
# ArchoeraMusic vault（凭据保险库）构建脚本（幂等）。
#
# 产物：vault/build/archoera-vault[.exe]
#   NativeAOT 单文件可执行（无 .NET 运行时依赖），按需会话进程，
#   经 stdin/stdout 行协议服务凭据（init/set/get/delete/destroy/status）。
#
# 依赖：.NET 10+ SDK（dotnet --version）；NativeAOT 需 clang 等 C 编译链。
# 使用：./build.sh [RID]     # RID 默认 linux-x64；三端：linux-x64 / win-x64 / osx-x64（或 osx-arm64）
set -euo pipefail
cd "$(dirname "$0")"

RID="${1:-linux-x64}"
case "$RID" in
  *win*) EXE="archoera-vault.exe" ;;
  *) EXE="archoera-vault" ;;
esac

mkdir -p build

# 用 -o 固定 publish 输出目录（不依赖 bin/Release/<tfm>/<rid> 路径，
# Windows 的 AOT 输出还带 x64 前缀，随 TFM 升级会漂移）。
dotnet publish src/Vault.csproj \
  -c Release \
  -r "$RID" \
  -o build/publish

cp "build/publish/$EXE" "build/$EXE"

echo "vault 产物就绪:"
ls -lh "build/$EXE"
