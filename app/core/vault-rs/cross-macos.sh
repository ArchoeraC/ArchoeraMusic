#!/usr/bin/env bash
# ArchoeraMusic vault（Rust）macOS 目标**交叉编译检查**（Linux 宿主，无需 Mac）。
#
# 作用：在非 macOS 机器上验证 `cfg(target_os = "macos")` 分支（Keychain 后端
# `security-framework`、`proc_pidpath` 的 dlopen/dlsym 回退、RLIMIT_CORE 等）
# **可编译可链接**，并产出双架构 universal（与 `app/core/build-macos.sh` 的 lipo
# 步骤同构）。**不覆盖运行期**：Mach-O 无法在 Linux 执行，Keychain / `proc_pidpath`
# / `DYLD_INSERT_LIBRARIES` 拒绝等行为仍须 macOS 真机（见 docs/vault-security-notes.md）。
#
# 依赖：rustup（已 `rustup target add aarch64-apple-darwin x86_64-apple-darwin`）、
#       clang + ld64.lld（LLVM）、macOS SDK（`MACOS_SDK` 指定，或自动探测
#       `~/Library/...`/`~/.local/share/macos-sdk/MacOSX*.sdk`/`xcrun --show-sdk-path`）、
#       llvm-lipo / llvm-otool（可选，用于合包与元数据校验）。缺任一 → 打印跳过原因并退出 0。
#
# 用法：./cross-macos.sh            # 测试构建（-TEST 标记）
#       ./cross-macos.sh --prod     # 生产构建（build.sh 同参数）
set -euo pipefail
cd "$(dirname "$0")"

PROD=0
[ "${1:-}" = "--prod" ] && PROD=1

skip() { echo "[cross-macos] 跳过：$*" >&2; exit 0; }
command -v clang >/dev/null 2>&1 || skip "未检测到 clang"
command -v rustup >/dev/null 2>&1 || skip "未检测到 rustup"

SDK="${MACOS_SDK:-}"
if [ -z "$SDK" ]; then
  for c in "$HOME/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk" \
           $(ls -d "$HOME/.local/share/macos-sdk"/MacOSX*.sdk 2>/dev/null || true) \
           $(ls -d /opt/MacOSX*.sdk 2>/dev/null || true); do
    [ -d "$c" ] && SDK="$c" && break
  done
fi
if [ -z "$SDK" ] && command -v xcrun >/dev/null 2>&1; then
  SDK="$(xcrun --show-sdk-path 2>/dev/null || true)"
fi
[ -n "$SDK" ] && [ -d "$SDK" ] || skip "未找到 macOS SDK（用 MACOS_SDK 指定）"
case "$SDK" in */) SDK="${SDK%/}";; esac

for t in aarch64-apple-darwin x86_64-apple-darwin; do
  rustup target add "$t" >/dev/null 2>&1 || true
  rustup target list --installed | grep -qx "$t" || skip "缺少 rust target $t"
done

# 链接驱动：clang 需显式 --target / -isysroot（rustc 不会代为传递）；
# 用 ld64.lld 避免依赖 Xcode 的 ld64。
WRAP_DIR="$(mktemp -d)"
trap 'rm -rf "$WRAP_DIR"' EXIT
for t in aarch64 x86_64; do
  cat > "$WRAP_DIR/cc-$t-darwin.sh" <<EOF
#!/bin/sh
exec clang --target=$t-apple-darwin -isysroot "$SDK" -fuse-ld=lld "\$@"
EOF
  chmod +x "$WRAP_DIR/cc-$t-darwin.sh"
done
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
export SDKROOT="$SDK"
export CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER="$WRAP_DIR/cc-aarch64-darwin.sh"
export CARGO_TARGET_X86_64_APPLE_DARWIN_LINKER="$WRAP_DIR/cc-x86_64-darwin.sh"

if [ "$PROD" = 1 ]; then
  FEATURES=()
  # 注意：macOS 上的 build-macos.sh 会把产物合包为 `build/archoera-vault`（Xcode 拷贝
  # 阶段与 CI bundle 步骤按该名取用）。此处刻意用 `-macos` 后缀，避免在 Linux 上
  # 覆盖 build.sh 产出的同名 Linux 静态单文件。
  OUT="build/archoera-vault-macos"
else
  FEATURES=(--features vault_testing)
  OUT="build/archoera-vault-macos-test"
fi

echo "[cross-macos] SDK=$SDK min=$MACOSX_DEPLOYMENT_TARGET 构建双架构…"
for t in aarch64-apple-darwin x86_64-apple-darwin; do
  cargo build --release --target "$t" "${FEATURES[@]}"
done

mkdir -p build
if command -v llvm-lipo >/dev/null 2>&1; then
  llvm-lipo -create -output "$OUT" \
    target/aarch64-apple-darwin/release/archoera-vault \
    target/x86_64-apple-darwin/release/archoera-vault
  echo "[cross-macos] universal 产物（llvm-lipo）："
  file "$OUT"
  llvm-lipo -info "$OUT"
elif command -v lipo >/dev/null 2>&1; then
  lipo -create -output "$OUT" \
    target/aarch64-apple-darwin/release/archoera-vault \
    target/x86_64-apple-darwin/release/archoera-vault
  file "$OUT"
else
  # 无 lipo 工具：至少校验两个单架构 Mach-O 产物（CI/真机的 build-macos.sh 负责合包）
  OUT=""
  file target/aarch64-apple-darwin/release/archoera-vault \
       target/x86_64-apple-darwin/release/archoera-vault
fi

# 元数据校验：minos（部署目标）与关键框架链接
if [ -n "$OUT" ] && command -v llvm-otool >/dev/null 2>&1; then
  MINOS="$(llvm-otool -l "$OUT" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
  LIBS="$(llvm-otool -L "$OUT" | tail -n +2 | awk '{print $1}')"
  echo "[cross-macos] minos=$MINOS"
  echo "$LIBS" | sed 's/^/  link: /'
  [ "$MINOS" = "$MACOSX_DEPLOYMENT_TARGET" ] || { echo "✗ minos($MINOS) ≠ 部署目标($MACOSX_DEPLOYMENT_TARGET)" >&2; exit 1; }
  case "$LIBS" in *Security.framework*) : ;; *) echo "✗ 未链接 Security.framework（Keychain 后端缺失）" >&2; exit 1;; esac
fi

echo "[cross-macos] 交叉编译检查通过 ✔（运行期行为仍须 macOS 真机）"
if [ -n "$OUT" ]; then ls -lh "$OUT"; else ls -lh target/*-apple-darwin/release/archoera-vault; fi
