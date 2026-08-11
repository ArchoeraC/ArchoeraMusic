# RPM 打包定义（Fedora / RHEL / openSUSE 系）
# 由 packaging/linux/package.sh rpm 调用 rpmbuild 构建：
#   rpmbuild -bb --define "stage_path <abs>" --define "app_version <ver>" ...
# 产物：archoera-music-<version>-1.x86_64.rpm

Name:           archoera-music
Version:        %{app_version}
Release:        1
Summary:        An open-source music player
License:        AGPL-3.0-only
URL:            https://github.com/BetaStudio2/ArchoeraMusic
BuildArch:      x86_64
Group:          Applications/Multimedia
AutoReqProv:    no
Requires:       glibc, libstdc++, zlib, gtk3, libayatana-appindicator, libdbusmenu-glib, libepoxy, fontconfig, fribidi, libX11, libXi, at-spi2-atk, libcloudproviders, ffmpeg-libs, taglib, libcurl, openssl-libs, sqlite-libs, xz-libs

%description
ArchoeraMusic is an open-source music player that connects to alternative
music services, supports offline playback, local library scanning and a
built-in subsonic-compatible server.

%prep

%build

%install
# 整个 bundle 装到 /opt/archoera-music（FFI/引擎子进程均相对可执行文件定位）
mkdir -p %{buildroot}/opt/archoera-music
cp -a %{stage_path}/bundle/. %{buildroot}/opt/archoera-music/
mkdir -p %{buildroot}/usr/bin
ln -s /opt/archoera-music/archoera_music %{buildroot}/usr/bin/archoera_music
# 桌面条目 + metainfo + 图标（文件名 = 应用 ID，保证 Wayland 任务栏图标映射）
mkdir -p %{buildroot}/usr/share/applications
install -m 644 %{stage_path}/archoera-music.desktop \
  %{buildroot}/usr/share/applications/com.archoera.archoera_music.desktop
mkdir -p %{buildroot}/usr/share/metainfo
install -m 644 %{stage_path}/com.archoera.archoera_music.metainfo.xml \
  %{buildroot}/usr/share/metainfo/com.archoera.archoera_music.metainfo.xml
# 先建 icons 目录再 cp -a：否则 hicolor 层级会被吞掉（icons 直接落在 icons/ 下，
# 导致 %files 的 hicolor/*/apps/*.png 通配匹配不到——CI 曾因此失败）
mkdir -p %{buildroot}/usr/share/icons
cp -a %{stage_path}/icons/hicolor %{buildroot}/usr/share/icons/

%files
/opt/archoera-music
/usr/bin/archoera_music
/usr/share/applications/com.archoera.archoera_music.desktop
/usr/share/metainfo/com.archoera.archoera_music.metainfo.xml
/usr/share/icons/hicolor/*/apps/com.archoera.archoera_music.png
