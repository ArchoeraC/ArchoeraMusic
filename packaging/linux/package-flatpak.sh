#!/usr/bin/env bash
# ArchoeraMusic Flatpak 打包（"包装预构建 bundle"方式，无需 flatpak-builder 从源码构建）。
#
# 用法：
#   package-flatpak.sh <bundle> <版本>
# 产物：dist/linux/ArchoeraMusic-v<版本>-linux-x86_64.flatpak
#
# 前置：flatpak 已安装，且已配置 flathub remote（脚本自动安装 Platform 运行时）。
# 说明：bundle 整体放入 /app（files/），以保留 FFI/引擎子进程的相对路径；
#       /app/bin/archoera_music 为包装脚本，真正入口是 /app/archoera_music。
set -euo pipefail

APP_NAME="ArchoeraMusic"
APP_ID="com.archoera.archoera_music"
BIN="archoera_music"
RUNTIME="org.freedesktop.Platform//24.08"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DIST="$ROOT/dist/linux"
WORK="$HERE/work"

bundle="${1:-}"; version="${2:-}"
if [[ -z "$bundle" || -z "$version" ]]; then
  echo "用法: package-flatpak.sh <bundle路径> <版本>" >&2
  exit 2
fi
bundle="$(cd "$bundle" && pwd)"

appdir="$WORK/flatpak-app"
repo="$WORK/flatpak-repo"
mkdir -p "$DIST" "$WORK"
rm -rf "$appdir" "$repo"

flatpak --user remote-add --if-not-exists flathub \
  https://flathub.org/repo/flathub.flatpakrepo
flatpak --user install -y --noninteractive "$RUNTIME"

# 1) init：SDK 与 Runtime 都指向 Platform（本方式不编译，无需完整 SDK）。
#    注：build-* 系列命令只操作本地目录，不接受 --user（报 Unknown option）。
flatpak build-init "$appdir" "$APP_ID" "$RUNTIME" "$RUNTIME"

# 2) 放入 bundle（/app 根布局与 tar.gz 完全一致）
cp -a "$bundle/." "$appdir/files/"

# 3) 包装脚本 + 桌面条目 + metainfo + 图标
mkdir -p "$appdir/files/bin" \
  "$appdir/files/share/applications" \
  "$appdir/files/share/metainfo"
cat > "$appdir/files/bin/$BIN" <<EOF
#!/bin/sh
exec /app/$BIN "\$@"
EOF
chmod +x "$appdir/files/bin/$BIN"
sed "s|@EXEC@|/app/bin/$BIN %U|g" "$HERE/archoera-music.desktop.in" \
  > "$appdir/files/share/applications/$APP_ID.desktop"
sed "s|@VERSION@|$version|g" \
  "$HERE/com.archoera.archoera_music.metainfo.xml.in" \
  > "$appdir/files/share/metainfo/$APP_ID.metainfo.xml"
for size in 32 48 64 128 256 512; do
  icon="$ROOT/app/linux/runner/resources/app_icon_${size}.png"
  [[ -f "$icon" ]] || continue
  install -Dm644 "$icon" \
    "$appdir/files/share/icons/hicolor/${size}x${size}/apps/$APP_ID.png"
done

# 4) finish：网络（媒体服务）、音频、图形（X11/Wayland/DRI）、home（本地曲库）
flatpak build-finish \
  --command=$BIN \
  --share=ipc --share=network \
  --socket=x11 --socket=wayland --socket=pulseaudio \
  --device=dri --filesystem=home \
  "$appdir"

# 5) 导出 + 打包为单文件 .flatpak
flatpak build-export --no-update-summary "$repo" "$appdir"
flatpak build-bundle "$repo" \
  "$DIST/$APP_NAME-v$version-linux-x86_64.flatpak" "$APP_ID"
echo "→ $DIST/$APP_NAME-v$version-linux-x86_64.flatpak"
