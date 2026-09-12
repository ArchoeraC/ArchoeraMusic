# ArchoeraMusic NixOS 打包定义（消费预构建 bundle，等价 Arch PKGBUILD）。
#
# 由 package.sh nix 预置：本文件与 bundle/、archoera-music.desktop、
# awa.archoera.betastudio2.archoera_music.png 同目录，版本号经 sed 注入下方
# version（占位 @VERSION@ 由 package.sh 替换为实际版本）。
#
# 二进制为 Release 预 strip 产物（Flutter/Rust/Go/NativeAOT/C 全无调试符号），
# autoPatchelfHook 负责两件 NixOS 必需的事：
#   ① 可执行文件 --set-interpreter（NixOS 无 /lib64/ld-linux-x86-64.so.2）；
#   ② 为 $out 下所有 ELF 追加 buildInputs 的 nix store 路径 RUNPATH
#      （NixOS 无 /usr/lib，GTK/openssl/curl/sqlite 等系统库只能从 store 解析）。
# FFmpeg（自建最小纯 LGPL）与 TagLib 随 bundle 内嵌于 native/ 且带 RUNPATH=$ORIGIN，
# 只依赖 libc/libm/libz，无需 store 提供（见 autoPatchelfIgnoreMissingDeps）。
# bundle 内相对定位（$ORIGIN / 相对可执行文件路径）保持原样，不改布局。

{ lib
, stdenv
, autoPatchelfHook
, gtk3
  # tray 插件链 libayatana-appindicator → libayatana-indicator + libdbusmenu-gtk3
  # → ayatana-ido。包名以 nixpkgs 源码为准（epoxy→libepoxy、
  # libayatana-indicator3→libayatana-indicator、libayatana-ido→ayatana-ido、
  # libdbusmenu→libdbusmenu-gtk3）；显式列全链路，不依赖 propagate。
, libayatana-appindicator
, libayatana-indicator
, ayatana-ido
, libdbusmenu-gtk3
, libepoxy
, fontconfig
, fribidi
, libX11
, libXi
, at-spi2-atk
, libcloudproviders
  # 运行库自包含：FFmpeg（自建最小纯 LGPL）与 TagLib 已随 bundle 内嵌于 native/
  # 并带 RUNPATH=$ORIGIN，只依赖 libc/libm/libz（store 提供）。故不再需要
  # ffmpeg/taglib 的 buildInputs；这些内嵌 soname 由 $ORIGIN 解析，
  # autoPatchelfHook 对「store 里找不到」忽略即可（见 autoPatchelfIgnoreMissingDeps）。
, curl # libcurl.so.4（scraper）
, openssl_3 # libcrypto.so.3（scraper）
, sqlite # libsqlite3.so.0（scraper）
, xz
, zlib
, glibc
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "archoera-music";
  version = "@VERSION@"; # package.sh 注入；手动 nix build 前需先替换

  src = ./bundle; # package.sh 预置的构建产物（保持完整目录结构）

  nativeBuildInputs = [ autoPatchelfHook ];

  buildInputs = [
    gtk3
    libayatana-appindicator
    libayatana-indicator
    ayatana-ido
    libdbusmenu-gtk3
    libepoxy
    fontconfig
    fribidi
    libX11
    libXi
    at-spi2-atk
    libcloudproviders
    curl
    openssl_3
    sqlite
    xz
    zlib
    glibc
  ];

  # 内嵌运行库（native/ 下的 libav* / libtag）由 RUNPATH=$ORIGIN 解析，store 中
  # 没有对应 soname；显式忽略，避免 autoPatchelfHook 报「找不到依赖」而失败。
  # 这些 soname 跟随内嵌的 FFmpeg 7.1.1 / TagLib 版本（升级时同步更新）。
  autoPatchelfIgnoreMissingDeps = [
    "libavformat.so.61"
    "libavcodec.so.61"
    "libavutil.so.59"
    "libswresample.so.5"
    "libtag.so.1"
    "libtag.so.2"
  ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/archoera-music $out/bin
    cp -a $src/. $out/lib/archoera-music/
    # 保留内嵌 FFmpeg/TagLib（自包含，$ORIGIN 解析）；autoPatchelfHook 只需补
    # 解释器与 libc/libm/libz 的 store RUNPATH（见 buildInputs）。
    chmod -R u+w $out/lib/archoera-music
    ln -s $out/lib/archoera-music/archoera_music $out/bin/archoera_music
    # 桌面条目 + 图标（文件名 = 应用 ID，保证 Wayland 任务栏图标映射）
    install -Dm644 ${./archoera-music.desktop} \
      $out/share/applications/awa.archoera.betastudio2.archoera_music.desktop
    install -Dm644 ${./awa.archoera.betastudio2.archoera_music.png} \
      $out/share/icons/hicolor/512x512/apps/awa.archoera.betastudio2.archoera_music.png
    runHook postInstall
  '';

  meta = {
    description = "An open-source music player, connect to alternative music service, support offline playback";
    homepage = "https://github.com/BetaStudio2/ArchoeraMusic";
    license = lib.licenses.agpl3Only;
    platforms = [ "x86_64-linux" ];
  };
})
