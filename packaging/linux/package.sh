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
APP_ID="awa.archoera.betastudio2.archoera_music"
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

# 产物文件名里的发行版标识与构建基线（CI 按 job 传入，如 ubuntu24.04 / deepin25 / fedora / arch）。
# 用于让用户一眼看出「这个包给谁用」，而不是只能靠后缀猜。
DISTRO_TAG="${DISTRO_TAG:-linux}"
BUILD_BASE="${BUILD_BASE:-$DISTRO_TAG}"
# 可选的适用性说明（如「仅 Deepin 25」）：写入 BUILD-INFO 与 deb control 描述。
DISTRO_NOTE="${DISTRO_NOTE:-}"

mkdir -p "$DIST"
stage="$WORK/stage"
rm -rf "$WORK"; mkdir -p "$stage"

# ── 公共暂存：bundle + 桌面条目 + metainfo + 多尺寸图标 ──────────────
cp -a "$bundle" "$stage/bundle"

# 防伪：把**公开公钥**随包分发（供用户验签；私钥绝不出现在包内）。
# 公钥同时已编译进 app（lib/app/watermark.dart），此处放置一份便于人读/离线验签。
if [[ -f "$ROOT/app/tool/watermark_pub.pem" ]]; then
  cp "$ROOT/app/tool/watermark_pub.pem" "$stage/bundle/ARCHOERA_PUBKEY.pem"
fi

sed "s|@EXEC@|/usr/bin/$BIN %U|g" "$HERE/archoera-music.desktop.in" \
  > "$stage/archoera-music.desktop"
sed "s|@VERSION@|$version|g" \
  "$HERE/awa.archoera.betastudio2.archoera_music.metainfo.xml.in" \
  > "$stage/awa.archoera.betastudio2.archoera_music.metainfo.xml"

for size in 32 48 64 128 256 512; do
  icon="$ROOT/app/linux/runner/resources/app_icon_${size}.png"
  [[ -f "$icon" ]] || continue
  install -Dm644 "$icon" \
    "$stage/icons/hicolor/${size}x${size}/apps/$APP_ID.png"
done

stage_bundle="$stage/bundle"
stage_desktop="$stage/archoera-music.desktop"
stage_metainfo="$stage/awa.archoera.betastudio2.archoera_music.metainfo.xml"
stage_icons="$stage/icons"

# ── BUILD-INFO.txt：产物内显著标识（发行版 / 基线 / glibc 最低要求）──────
# 随每个包分发（进 bundle 根），让用户无需靠文件名后缀猜适用性。
write_build_info() {
  local glibc_max=""
  if command -v objdump >/dev/null 2>&1; then
    glibc_max="$(find "$stage_bundle" -type f \
        \( -name '*.so*' -o -perm -u+x \) -print0 2>/dev/null \
      | xargs -0 -r objdump -T 2>/dev/null \
      | grep -o 'GLIBC_[0-9.]*' | sort -V | uniq | tail -1 || true)"
  fi
  cat > "$stage_bundle/BUILD-INFO.txt" <<EOF
ArchoeraMusic $version
构建目标   : $DISTRO_TAG
构建基线   : $BUILD_BASE
适用系统   : ${DISTRO_NOTE:-通用（见最低 glibc）}
最低 glibc : ${glibc_max:-未知}
构建时间   : $(date -u +%Y-%m-%dT%H:%M:%SZ)
提交       : ${GITHUB_SHA:-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)}
运行库     : FFmpeg 7.1.1（自建最小纯 LGPL）、TagLib 已内嵌于 native/（RUNPATH=\$ORIGIN）
许可       : AGPL-3.0（见 LICENSE）；第三方许可见 licenses/
EOF
}
write_build_info

# ── tar.gz：纯二进制（保留 bundle 原结构，解压即用）───────────────────
pkg_tar() {
  local dir="$stage/tar/ArchoeraMusic-linux-x86_64"
  mkdir -p "$stage/tar"
  cp -a "$stage_bundle" "$dir"
  tar -C "$stage/tar" -czf \
    "$DIST/$APP_NAME-v$version-linux-x86_64.tar.gz" \
    "$(basename "$dir")"
  echo "→ $DIST/$APP_NAME-v$version-linux-x86_64.tar.gz"
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

  # 注：DEBIAN/control 是 dpkg 格式，不允许 '#' 注释行，说明性注释只能放此处。
  cat > "$root/DEBIAN/control" <<EOF
Package: archoera-music
Version: $version_deb
Section: sound
Priority: optional
Architecture: amd64
Maintainer: BetaStudio2 (ArchoeraMusic) <noreply@github.com>
Homepage: $REPO_URL
Depends: libc6, libstdc++6, zlib1g, libgtk-3-0 | libgtk-3-0t64, libayatana-appindicator3-1, libdbusmenu-glib4, libdbus-1-3, libepoxy0, libfontconfig1, libfribidi0, libx11-6, libxi6, libatk-bridge2.0-0, libcloudproviders0, libcurl4, libssl3, libsqlite3-0, liblzma5
Description: An open-source music player
 Connect to alternative music services, support offline playback, local
 library scanning and a built-in subsonic-compatible server.
EOF
  # 发行版专属适用性说明（如「仅 Deepin 25」），作为 Description 的续行
  if [[ -n "$DISTRO_NOTE" ]]; then
    printf ' 适用系统: %s\n' "$DISTRO_NOTE" >> "$root/DEBIAN/control"
  fi
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
    "$DIST/$APP_NAME-v$version_deb-${DISTRO_TAG}-x86_64.deb" >/dev/null
  echo "→ $DIST/$APP_NAME-v$version_deb-${DISTRO_TAG}-x86_64.deb"
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
  # 统一命名为 <App>-v<ver>-<发行版>-x86_64.rpm（显著标识发行版；rpm 内部元数据不变）。
  local src
  src="$(find "$topdir/RPMS" -name '*.rpm' | head -1)"
  cp "$src" "$DIST/$APP_NAME-v$version-${DISTRO_TAG}-x86_64.rpm"
  echo "→ $DIST/$APP_NAME-v$version-${DISTRO_TAG}-x86_64.rpm"
}

# ── AppImage：通用便携 ────────────────────────────────────────────────
# 关键：AppImage 要跨发行版运行，必须把构建机的动态依赖（GTK / FFmpeg /
# TagLib 等）一并收拢进镜像。仅拷贝 bundle 时，引擎（FFmpeg）与 scraper
# （TagLib）在 soname 不同的发行版上会加载失败。故用 linuxdeploy 收集依赖
# 进 usr/lib 并改写 RUNPATH（构建机为 Ubuntu，故收拢的是 Ubuntu 库，任意
# 发行版均可加载）。
pkg_appimage() {
  local appdir="$stage/appimage/ArchoeraMusic.AppDir"
  mkdir -p "$appdir/usr/bin" "$appdir/usr/share/applications" \
    "$appdir/usr/share/metainfo" \
    "$appdir/usr/share/icons/hicolor/512x512/apps"
  # 应用本体整份入 usr/bin（exe 相对定位 data/、native/ 不变）
  cp -a "$stage_bundle/." "$appdir/usr/bin/"
  chmod +x "$appdir/usr/bin/$BIN"

  sed "s|@EXEC@|$BIN %U|g" "$HERE/archoera-music.desktop.in" \
    > "$appdir/usr/share/applications/archoera-music.desktop"
  cp "$stage_icons/hicolor/512x512/apps/$APP_ID.png" \
    "$appdir/usr/share/icons/hicolor/512x512/apps/$APP_ID.png"
  install -m644 "$stage_metainfo" \
    "$appdir/usr/share/metainfo/$APP_ID.metainfo.xml"

  # linuxdeploy 装配：收拢可执行文件与发行版敏感库的动态依赖，生成 AppRun。
  # LINUXDEPLOY 由 CI 传入（linuxdeploy-x86_64.AppImage）；缺失时退化为纯拷贝
  # （产物仅在构建机同系发行版可用，并打印告警）。
  local ld="${LINUXDEPLOY:-}"
  if [[ -n "$ld" && -x "$ld" ]]; then
    local lib_args=()
    for lib in libarchoera_mediaengine.so libarchoera_scraper.so; do
      [[ -f "$appdir/usr/bin/native/$lib" ]] && \
        lib_args+=(--library "$appdir/usr/bin/native/$lib")
    done
    "$ld" --appdir "$appdir" \
      --executable "$appdir/usr/bin/$BIN" \
      "${lib_args[@]}" \
      --desktop-file "$appdir/usr/share/applications/archoera-music.desktop" \
      --icon-file "$appdir/usr/share/icons/hicolor/512x512/apps/$APP_ID.png"
  else
    echo "警告: 未提供 LINUXDEPLOY，AppImage 不收拢依赖（仅构建机同系发行版可用）" >&2
  fi

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
    "$nix_dir/awa.archoera.betastudio2.archoera_music.png"
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
