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

# 真实播放器 bundle（若已构建）：装进 /opt/archoera-music 供 kiosk 会话启动。
REPO="$(cd "$OS/.." && pwd)"
BUNDLE="$REPO/app/build/linux/x64/release/bundle"
if [ -x "$BUNDLE/archoera_music" ]; then
    echo "==> 打包播放器 bundle: $BUNDLE"
    rm -rf "$HERE/mkosi.extra/opt/archoera-music"
    mkdir -p "$HERE/mkosi.extra/opt/archoera-music"
    cp -a "$BUNDLE/." "$HERE/mkosi.extra/opt/archoera-music/"
else
    echo "==> 未找到播放器 bundle（$BUNDLE），VM 内将回退 smoke"
fi

chmod 0755 "$HERE/mkosi.extra/usr/local/bin/archoera-session" 2>/dev/null || true

# Plymouth 主题：唯一来源在 mkosi.extra，同步一份进 mkosi.initrd.extra（initrd 阶段也要用）。
if [ -d "$HERE/mkosi.extra/usr/share/plymouth/themes/archoera" ]; then
    rm -rf "$HERE/mkosi.initrd.extra/usr/share/plymouth/themes/archoera"
    mkdir -p "$HERE/mkosi.initrd.extra/usr/share/plymouth/themes"
    cp -a "$HERE/mkosi.extra/usr/share/plymouth/themes/archoera" \
          "$HERE/mkosi.initrd.extra/usr/share/plymouth/themes/"
fi

# 光标主题：把宿主当前使用的 XCursor 主题复制进镜像（用户要求「用我在用的那套」）。
# 主题名取自 KDE（kcminputrc）或 gsettings，缺省 Adwaita（镜像自带）。
cursor_theme=""
if [ -r "$HOME/.config/kcminputrc" ]; then
    cursor_theme="$(sed -n 's/^cursorTheme=//p' "$HOME/.config/kcminputrc" | head -1)"
fi
if [ -z "$cursor_theme" ] && command -v gsettings >/dev/null 2>&1; then
    cursor_theme="$(gsettings get org.gnome.desktop.interface cursor-theme 2>/dev/null | tr -d "'")"
fi
if [ -z "$cursor_theme" ] || [ ! -d "/usr/share/icons/$cursor_theme/cursors" ]; then
    cursor_theme=Adwaita
fi
cursor_size=""
if [ -r "$HOME/.config/kcminputrc" ]; then
    cursor_size="$(sed -n 's/^cursorSize=//p' "$HOME/.config/kcminputrc" | head -1)"
fi
[ -n "$cursor_size" ] || cursor_size=24

if [ ! -d "$HERE/mkosi.extra/usr/share/icons/$cursor_theme/cursors" ]; then
    echo "==> 复制光标主题: $cursor_theme (size=$cursor_size)"
    rm -rf "$HERE/mkosi.extra/usr/share/icons/$cursor_theme"
    mkdir -p "$HERE/mkosi.extra/usr/share/icons"
    cp -a "/usr/share/icons/$cursor_theme" "$HERE/mkosi.extra/usr/share/icons/"
fi
mkdir -p "$HERE/mkosi.extra/opt/archoera"
printf '%s\n%s\n' "$cursor_theme" "$cursor_size" > "$HERE/mkosi.extra/opt/archoera/cursor-theme"

if [ "$PROFILE" = "vm" ]; then
    # 无头 VM 默认不带 GPU（mkosi 仅在 Console=gui 时加 virtio-gpu-pci），
    # 这里显式补上 GPU 与输入设备，供 udev/DRM 后端验证。
    exec mkosi -C "$HERE" --force vm -- \
        -device virtio-gpu-pci \
        -device virtio-keyboard-pci \
        -device virtio-tablet-pci \
        -device virtio-multitouch-pci \
        "$@"
fi

mkosi -C "$HERE" --force "$PROFILE" "$@"
rc=$?

# Live profile：产物（El Torito 混合镜像）同时是 ISO —— 硬链接一份 .iso 便于刻录/分发
# （同 inode，不额外占空间）。注意必须在构建**之后**执行。
if [[ " $* " == *" --profile live "* ]] || [[ " $* " == *"--profile=live"* ]]; then
    RAW="$HERE/mkosi.output/archoera-live.raw"
    if [ -f "$RAW" ]; then
        ln -f "$RAW" "$HERE/mkosi.output/archoera-live.iso"
        echo "==> Live ISO: $HERE/mkosi.output/archoera-live.iso"
        echo "    写 U 盘: dd if=mkosi.output/archoera-live.iso of=/dev/sdX bs=4M status=progress oflag=sync"
    fi
fi
exit $rc
