#!/usr/bin/env bash
# 构建 ArchoeraOS 最小 VM：先编 release 二进制并放进镜像，再调 mkosi。
#
#   os/vm/build.sh            # 只构建镜像（mkosi build）
#   os/vm/build.sh vm         # 构建并启动虚拟机（mkosi vm）
#   os/vm/build.sh vm -- --ram=2G   # 透传额外 mkosi/vm 参数（在 -- 之后）
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OS="$(cd "$HERE/.." && pwd)"
PROFILE="${1:-build}"
if [ $# -gt 0 ]; then shift; fi

cargo build --release --manifest-path "$OS/Cargo.toml" \
    -p archoera-control -p archoera-smoke
# udev 后端需显式启用 feature（DRM/KMS + libinput + libseat）。
cargo build --release --manifest-path "$OS/Cargo.toml" \
    -p archoera-shell --features udev

mkdir -p "$HERE/mkosi.extra/opt/archoera"
for bin in archoera-shell archoera-control archoera-smoke; do
    install -m 0755 "$OS/target/release/$bin" "$HERE/mkosi.extra/opt/archoera/$bin"
done
chmod 0755 "$HERE/mkosi.extra/usr/local/bin/archoera-session" 2>/dev/null || true

if [ "$PROFILE" = "vm" ]; then
    # 无头 VM 默认不带 GPU（mkosi 仅在 Console=gui 时加 virtio-gpu-pci），
    # 这里显式补上 GPU 与输入设备，供 udev/DRM 后端验证。
    exec mkosi -C "$HERE" --force vm -- \
        -device virtio-gpu-pci \
        -device virtio-keyboard-pci \
        -device virtio-tablet-pci \
        "$@"
fi

exec mkosi -C "$HERE" --force "$PROFILE" "$@"
