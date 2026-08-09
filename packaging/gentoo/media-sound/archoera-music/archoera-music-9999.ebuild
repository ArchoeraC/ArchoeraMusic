# Copyright 1999-2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

# Gentoo ebuild（二进制发布包：直接消费 GitHub Release 的纯二进制 tar.gz）。
# 放置于 overlay：media-sound/archoera-music/archoera-music-9999.ebuild
# 或按版本号改名（如 archoera-music-0.8.4.ebuild）。

EAPI=8

inherit eutils

DESCRIPTION="An open-source music player, connect to alternative music service, support offline playback"
HOMEPAGE="https://github.com/BetaStudio2/ArchoeraMusic"
SRC_URI="https://github.com/BetaStudio2/ArchoeraMusic/releases/download/v${PV}/ArchoeraMusic-v${PV}-linux-x64.tar.gz"

LICENSE="AGPL-3"
SLOT="0"
KEYWORDS="~amd64"
RESTRICT="primaryuri strip"

RDEPEND="
	>=x11-libs/gtk+-3.24:3
	dev-libs/glib:2
	dev-libs/atk
	dev-libs/dbusmenu-glib
	dev-libs/libayatana-appindicator
	media-libs/fontconfig
	media-libs/fribidi
	x11-libs/libX11
	x11-libs/libXi
	media-video/ffmpeg
	media-libs/taglib
	net-misc/curl
	dev-libs/openssl
	dev-db/sqlite
	app-arch/xz-utils
	sys-libs/zlib
"

S="${WORKDIR}/ArchoeraMusic-linux-x64"

src_install() {
	# 整个 bundle 装到 /opt/archoera-music（FFI/引擎子进程相对可执行文件定位）
	insinto /opt/archoera-music
	doins -r "${S}"/.
	fperms 0755 /opt/archoera-music/archoera_music
	dosym /opt/archoera-music/archoera_music /usr/bin/archoera_music

	# 图标：bundle 内置 data/app_icon.png
	doicon -s 512 "${S}/data/app_icon.png"
	# 桌面条目（文件名 = 应用 ID，保证 Wayland 任务栏图标映射）
	newmenu - <<-EOF
		[Desktop Entry]
		Type=Application
		Name=ArchoeraMusic
		GenericName=Music Player
		Comment=An open-source music player
		Exec=/usr/bin/archoera_music %U
		Icon=com.archoera.archoera_music
		Terminal=false
		Categories=Audio;Music;AudioVideo;
		StartupWMClass=archoera_music
	EOF
}
