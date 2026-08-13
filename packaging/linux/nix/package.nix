# ArchoeraMusic NixOS 打包定义（消费预构建 bundle，等价 Arch PKGBUILD）。
#
# 由 package.sh nix 预置：本文件与 bundle/、archoera-music.desktop、
# com.archoera.archoera_music.png 同目录，版本号经 sed 注入下方
# version（占位 @VERSION@ 由 package.sh 替换为实际版本）。
#
# 二进制为 Release 预 strip 产物（Flutter/Rust/Go/NativeAOT/C 全无调试符号），
# autoPatchelfHook 负责两件 NixOS 必需的事：
#   ① 可执行文件 --set-interpreter（NixOS 无 /lib64/ld-linux-x86-64.so.2）；
#   ② 为 $out 下所有 ELF 追加 buildInputs 的 nix store 路径 RUNPATH
#      （NixOS 无 /usr/lib，GTK/FFmpeg/taglib/openssl/curl/sqlite 等
#      系统库只能从 store 解析）。
# bundle 内相对定位（$ORIGIN / 相对可执行文件路径）保持原样，不改布局。

{ lib
, stdenv
, autoPatchelfHook
, gtk3
, libayatana-appindicator
, libayatana-indicator3
, libayatana-ido
, libdbusmenu
, epoxy
, fontconfig
, fribidi
, libX11
, libXi
, at-spi2-atk
, libcloudproviders
  # mediaengine 链接的 FFmpeg soname 取决于构建机：CI（ubuntu-24.04
  # FFmpeg 7.0.1）→ libavformat.so.61；本地较新 FFmpeg → libavformat.so.62。
  # 两版本并存，autoPatchelfHook 按各 ELF 的 NEEDED 自动匹配。
, ffmpeg_7 # libavformat.so.61 / libavcodec.so.61
, ffmpeg_8 # libavformat.so.62 / libavcodec.so.62
, taglib # libtag.so.2（scraper）
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
    # tray 插件链 libayatana-indicator3/ido3：显式列出，不依赖 appindicator 的 propagate
    libayatana-appindicator
    libayatana-indicator3
    libayatana-ido
    libdbusmenu
    epoxy
    fontconfig
    fribidi
    libX11
    libXi
    at-spi2-atk
    libcloudproviders
    ffmpeg_7
    ffmpeg_8
    taglib
    curl
    openssl_3
    sqlite
    xz
    zlib
    glibc
  ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/archoera-music $out/bin
    cp -a $src/. $out/lib/archoera-music/
    ln -s $out/lib/archoera-music/archoera_music $out/bin/archoera_music
    # 桌面条目 + 图标（文件名 = 应用 ID，保证 Wayland 任务栏图标映射）
    install -Dm644 ${./archoera-music.desktop} \
      $out/share/applications/com.archoera.archoera_music.desktop
    install -Dm644 ${./com.archoera.archoera_music.png} \
      $out/share/icons/hicolor/512x512/apps/com.archoera.archoera_music.png
    runHook postInstall
  '';

  meta = {
    description = "An open-source music player, connect to alternative music service, support offline playback";
    homepage = "https://github.com/BetaStudio2/ArchoeraMusic";
    license = lib.licenses.agpl3Only;
    platforms = [ "x86_64-linux" ];
  };
})
