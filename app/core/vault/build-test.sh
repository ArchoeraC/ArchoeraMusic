#!/usr/bin/env bash
# ArchoeraMusic vault 测试构建（VAULT_TESTING 条件编译，幂等）。
#
# 产物：vault/build/archoera-vault-test[.exe]
#   与生产 build.sh 唯一区别：定义 VAULT_TESTING 常量 → 编译进
#   InsecureFileStore（测试明文存储）与对应工厂分支（SecretStores.cs）。
#   仅测试/CI 使用（无 Secret Service 的 headless 环境），绝不发布——
#   生产二进制由 build.sh 产出，不含任何测试明文存储逻辑。
#
# 依赖：.NET 10+ SDK；NativeAOT 需 clang 等 C 编译链。
# 使用：./build-test.sh [RID]   # RID 默认 linux-x64
set -euo pipefail
cd "$(dirname "$0")"

RID="${1:-linux-x64}"
case "$RID" in
  *win*) SRC="archoera-vault.exe"; OUT="archoera-vault-test.exe" ;;
  *) SRC="archoera-vault"; OUT="archoera-vault-test" ;;
esac

mkdir -p build

# PublishDir 隔离测试产物，避免与 build.sh 生产 publish 目录相互覆盖
# （DefineConstants 仅 VAULT_TESTING：源码不依赖 TRACE/RELEASE 默认常量；
#   产物文件名仍为 AssemblyName archoera-vault，拷贝时改名为 -test；
#   PublishDir 用绝对路径——相对路径基于 src/ 项目目录而非脚本 cwd）
dotnet publish src/Vault.csproj \
  -c Release \
  -r "$RID" \
  -p:DefineConstants="VAULT_TESTING" \
  -p:PublishDir="$PWD/build/publish-test/$RID/"

cp "$PWD/build/publish-test/$RID/$SRC" "build/$OUT"

echo "vault 测试产物就绪:"
ls -lh "build/$OUT"
