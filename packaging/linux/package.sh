#!/usr/bin/env bash
# ArchoeraMusic Linux 打包脚本（CI 与本地均可用）。
#
# 用法：
#   package.sh tar       <bundle> <版本>   → dist/linux/*.tar.gz          纯二进制（保留）
#   package.sh deb       <bundle> <版本>   → dist/linux/*.deb             Debian/Ubuntu 系
#   package.sh rpm       <bundle> <版本>   → dist/linux/*.rpm             Fedora/RHEL/openSUSE 系
#   package.sh appimage  <bundle> <版本>   → dist/linux/*.AppImage        通用便携
#   package.sh arch      <bundle> <版本>   → dist/linux/*.pkg.tar.zst     Arch/Manjaro 系
#                                          （arch 仅预置工作目录，makepkg 由
#                                            workflow 在 archlinux 容器内执行）
#   package.sh nix       <bundle> <版本>   → work/nix/ 预置 flake 工作目录
#                                          （bundle + desktop + icon + 版本注入，
#                                            nix build 由 workflow 在 nixos/nix 容器内执行）
#
# 说明：bundle 必须保持完整目录结构（FFI 与引擎子进程均相对可执行文件定位）。
set -euo pipefail

APP_NAME="ArchoeraMusic"
APP_ID="com.archoera.archoera_music"
BIN="archoera_music"
DEST_PREFIX="/opt/archoera-music"
REPO_URL="https://github.com/BetaStudio2/ArchoeraMusic"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DIST="$ROOT/dist/linux"
WORK="$HERE/work"

fmt="${1:-}"; bundle="${2:-}"; version="${3:-}"
if [[ -z "$fmt" || -z "$bundle" || -z "$version" ]]; then
  echo "用法: package.sh <tar|deb|rpm|appimage|arch|nix> <bundle路径> <版本>" >&2
  exit 2
fi
bundle="$(cd "$bundle" && pwd)"

# 各包管理器对版本号的限制
version_deb="$version"                    # deb 允许 . + -
version_rpm="${version//[+-]/_}"          # rpm 不允许 '+' 与 '-'（- 分隔 version-release）
version_arch="${version//[+-]/_}"         # arch pkgver 只允许 [A-Za-z0-9.]

mkdir -p "$DIST"
stage="$WORK/stage"
rm -rf "$WORK"; mkdir -p "$stage"

# ── 公共暂存：bundle + 桌面条目 + metainfo + 多尺寸图标 ──────────────
cp -a "$bundle" "$stage/bundle"

sed "s|@EXEC@|/usr/bin/$BIN %U|g" "$HERE/archoera-music.desktop.in" \
  > "$stage/archoera-music.desktop"
sed "s|@VERSION@|$version|g" \
  "$HERE/com.archoera.archoera_music.metainfo.xml.in" \
  > "$stage/com.archoera.archoera_music.metainfo.xml"

for size in 32 48 64 128 256 512; do
  icon="$ROOT/app/linux/runner/resources/app_icon_${size}.png"
  [[ -f "$icon" ]] || continue
  install -Dm644 "$icon" \
    "$stage/icons/hicolor/${size}x${size}/apps/$APP_ID.png"
done

stage_bundle="$stage/bundle"
stage_desktop="$stage/archoera-music.desktop"
stage_metainfo="$stage/com.archoera.archoera_music.metainfo.xml"
stage_icons="$stage/icons"

# ── tar.gz：纯二进制（保留 bundle 原结构，解压即用）───────────────────
pkg_tar() {
  local dir="$stage/tar/ArchoeraMusic-linux-x64"
  mkdir -p "$stage/tar"
  cp -a "$stage_bundle" "$dir"
  tar -C "$stage/tar" -czf \
    "$DIST/$APP_NAME-v$version-linux-x64.tar.gz" \
    "$(basename "$dir")"
  echo "→ $DIST/$APP_NAME-v$version-linux-x64.tar.gz"
}

# ── deb：Debian/Ubuntu 系 ─────────────────────────────────────────────
pkg_deb() {
  local root="$stage/deb"
  mkdir -p "$root$DEST_PREFIX" "$root/usr/bin" \
    "$root/usr/share/applications" "$root/usr/share/metainfo" \
    "$root/usr/share/icons" "$root/DEBIAN"
  cp -a "$stage_bundle/." "$root$DEST_PREFIX/"
  ln -s "$DEST_PREFIX/$BIN" "$root/usr/bin/$BIN"
  install -m644 "$stage_desktop" \
    "$root/usr/share/applications/$APP_ID.desktop"
  install -m644 "$stage_metainfo" \
    "$root/usr/share/metainfo/$APP_ID.metainfo.xml"
  cp -a "$stage_icons/hicolor" "$root/usr/share/icons/"

  cat > "$root/DEBIAN/control" <<EOF
Package: archoera-music
Version: $version_deb
Section: sound
Priority: optional
Architecture: amd64
Maintainer: BetaStudio2 (ArchoeraMusic) <noreply@github.com>
Homepage: $REPO_URL
# ffmpeg：内嵌 FFmpeg 库（libav*.so）的编解码传递依赖（libx264 等）供应者；
# 引擎链接的是 bundle 自带 soname，系统 FFmpeg 升级不再破坏应用（仅提供依赖库）。
Depends: libc6, libstdc++6, zlib1g, libgtk-3-0 | libgtk-3-0t64, libayatana-appindicator3-1, libdbusmenu-glib4, libepoxy0, libfontconfig1, libfribidi0, libx11-6, libxi6, libatk-bridge2.0-0, libcloudproviders0, ffmpeg, libtag1v5, libcurl4, libssl3, libsqlite3-0, liblzma5
Description: An open-source music player
 Connect to alternative music services, support offline playback, local
 library scanning and a built-in subsonic-compatible server.
EOF
  cat > "$root/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database -q /usr/share/applications || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q -t /usr/share/icons/hicolor || true
fi
exit 0
EOF
  chmod +x "$root/DEBIAN/postinst"
  cp "$root/DEBIAN/postinst" "$root/DEBIAN/postrm"

  dpkg-deb --root-owner-group --build "$root" \
    "$DIST/$APP_NAME-v$version_deb-linux-x64.deb" >/dev/null
  echo "→ $DIST/$APP_NAME-v$version_deb-linux-x64.deb"
}

# ── rpm：Fedora / RHEL / openSUSE 系 ──────────────────────────────────
pkg_rpm() {
  local topdir="$stage/rpmbuild"
  mkdir -p "$topdir"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
  cp "$HERE/archoera-music.spec" "$topdir/SPECS/"
  rpmbuild --define "_topdir $topdir" \
    --define "stage_path $stage" \
    --define "app_version $version_rpm" \
    --define "_rpmfilename %{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}.rpm" \
    -bb "$topdir/SPECS/archoera-music.spec"
  # _rpmfilename 被 --define 重写后 rpm 将包输出到 RPMS/ 根目录（而非按 arch 分目录），
  # 用 find 兜底定位，避免路径假设（CI 曾因硬编码 RPMS/x86_64/ 失败）。
  find "$topdir/RPMS" -name '*.rpm' -exec cp {} "$DIST/" \;
  echo "→ $DIST/$(ls "$DIST" | grep '\.rpm$' | tail -1)"
}

# ── AppImage：通用便携 ────────────────────────────────────────────────
pkg_appimage() {
  local appdir="$stage/appimage/ArchoeraMusic.AppDir"
  mkdir -p "$appdir/usr/lib/archoera-music" "$appdir/usr/share/metainfo" \
    "$appdir/usr/share/icons"
  cp -a "$stage_bundle/." "$appdir/usr/lib/archoera-music/"
  # AppRun 在 AppDir 内启动真实二进制（/proc/self/exe 相对路径保持正确）
  cat > "$appdir/AppRun" <<EOF
#!/bin/sh
exec "\$APPDIR/usr/lib/archoera-music/$BIN" "\$@"
EOF
  chmod +x "$appdir/AppRun"
  sed "s|@EXEC@|AppRun %U|g" "$HERE/archoera-music.desktop.in" \
    > "$appdir/ArchoeraMusic.desktop"
  sed -i "s|Icon=com.archoera.archoera_music|Icon=ArchoeraMusic|" \
    "$appdir/ArchoeraMusic.desktop"
  cp "$stage_icons/hicolor/512x512/apps/$APP_ID.png" "$appdir/ArchoeraMusic.png"
  cp -a "$stage_icons/hicolor" "$appdir/usr/share/icons/hicolor"
  install -m644 "$stage_metainfo" \
    "$appdir/usr/share/metainfo/$APP_ID.metainfo.xml"
  # CI 无 FUSE：用 --appimage-extract-and-run 运行 appimagetool 本体。
  # type2 runtime 经 APPIMAGE_RUNTIME_FILE 预下载传入，避免每次打包联网
  # 下载（CI 网络抖动时 appimagetool 内置 libcurl 易 TLS 失败）。
  if [[ -n "${APPIMAGE_RUNTIME_FILE:-}" && -f "$APPIMAGE_RUNTIME_FILE" ]]; then
    appimagetool --appimage-extract-and-run --runtime-file "$APPIMAGE_RUNTIME_FILE" \
      "$appdir" "$DIST/$APP_NAME-v$version-linux-x86_64.AppImage"
  else
    appimagetool --appimage-extract-and-run "$appdir" \
      "$DIST/$APP_NAME-v$version-linux-x86_64.AppImage"
  fi
  echo "→ $DIST/$APP_NAME-v$version-linux-x86_64.AppImage"
}

# ── arch：预置 makepkg 工作目录（容器内执行）─────────────────────────
pkg_arch() {
  local arch_dir="$WORK/arch"
  mkdir -p "$arch_dir"
  tar --zstd -C "$stage" -cf "$arch_dir/bundle.tar.zst" bundle
  cp "$HERE/PKGBUILD" "$arch_dir/PKGBUILD"
  sed -i "s|^pkgver=.*|pkgver=$version_arch|" "$arch_dir/PKGBUILD"
  cp "$stage_desktop" "$arch_dir/archoera-music.desktop"
  cp "$stage_icons/hicolor/512x512/apps/$APP_ID.png" \
    "$arch_dir/$APP_ID.png"
  # 运行 makepkg 的容器命令（由 workflow 执行）：
  echo "→ $arch_dir （docker: archlinux 容器内运行 makepkg -f --skipinteg --nocheck --nodeps）"
}

# ── nix：预置 flake 工作目录（nixos/nix 容器内执行 nix build）────────
pkg_nix() {
  local nix_dir="$WORK/nix"
  mkdir -p "$nix_dir"
  # 源定义在 packaging/linux/nix/（提交进 git），拷入工作目录并注入版本
  cp "$HERE/nix/flake.nix" "$nix_dir/flake.nix"
  sed "s|@VERSION@|$version|g" "$HERE/nix/package.nix" > "$nix_dir/package.nix"
  cp -a "$stage_bundle" "$nix_dir/bundle"
  cp "$stage_desktop" "$nix_dir/archoera-music.desktop"
  cp "$stage_icons/hicolor/512x512/apps/$APP_ID.png" \
    "$nix_dir/com.archoera.archoera_music.png"
  echo "→ $nix_dir （docker: nixos/nix 容器内运行 nix build .#default）"
}

case "$fmt" in
  tar)      pkg_tar ;;
  deb)      pkg_deb ;;
  rpm)      pkg_rpm ;;
  appimage) pkg_appimage ;;
  arch)     pkg_arch ;;
  nix)      pkg_nix ;;
  *) echo "未知格式: $fmt" >&2; exit 2 ;;
esac
