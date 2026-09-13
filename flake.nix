{
  # ArchoeraMusic —— NixOS「源构建」flake（脱离 Ubuntu/发行版，nixpkgs 工具链）。
  #
  # 拆成多个 derivation，便于**增量构建**：Nix 按输入哈希缓存成功产物，改动某一
  # 模块只重编它及其下游，已成功的阶段直接跳过。
  #   ffmpegMinimal → kernel → audioEngine / scraper / scanner / vault /
  #                   downloader / subsonic / platform → default(app)
  #
  # 构建需要联网（pub / NuGet / crates.io / go modules / FFmpeg 源码），故：
  #   nix build .#default --option sandbox false --print-build-logs
  #
  # 说明：FFmpeg 仍用仓库内 app/core/build-ffmpeg-minimal.sh 现场编**最小纯
  # LGPL·仅音频**版本（保持 GPL 防火墙与内嵌 native/ 布局一致），不用 nixpkgs
  # 的 ffmpeg（其构建含 GPL 组件）。

  description = "ArchoeraMusic — 开源音乐播放器（Nix 源构建）";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      inherit (pkgs) lib;

      # 源码树排除 flake.nix / flake.lock：编辑 flake 本身不会改变各 derivation
      # 的 src 哈希，已成功构建的阶段得以命中 Nix 缓存、直接跳过。
      src = lib.cleanSourceWith {
        src = self;
        filter =
          path: type:
          let
            b = baseNameOf path;
          in
          !(b == "flake.nix" || b == "flake.lock");
      };

      version =
        let
          m = builtins.match ".*version:[[:space:]]*([0-9]+\\.[0-9]+\\.[0-9]+\\+[0-9]+).*" (
            builtins.readFile ./app/pubspec.yaml
          );
        in
        if m == null then "0.0.0+0" else builtins.head m;

      # 各 derivation 共用的联网/缓存/HOME 环境。
      netEnv = ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        export DOTNET_CLI_HOME="$HOME"
        export DOTNET_NOLOGO=1
        export DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
        export NUGET_PACKAGES="$TMPDIR/nuget"
        export CARGO_HOME="$TMPDIR/cargo"
        export GOPATH="$TMPDIR/go"
        export GOCACHE="$TMPDIR/go-cache"
        export PUB_CACHE="$TMPDIR/pub-cache"
        export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        # signalsmith-stretch 的 bindgen 需要 libclang（用 Nix 的，勿命中宿主）
        export LIBCLANG_PATH="${pkgs.llvmPackages.libclang.lib}/lib"
        # Go 模块：默认走官方 proxy.golang.org（CI/GitHub 友好，勿硬编码国内源，
        # 否则 GitHub 上可能失败）。`|` 分隔表示任一错误即回退下一个。
        export GOPROXY="https://proxy.golang.org|direct"
        export GOSUMDB=off
        export GOTOOLCHAIN=local
        export GOFLAGS="-mod=mod"
        # 用满所有核心
        export JOBS="$(nproc)"
      '';

      # NuGet：跳过 Nix 的离线 _nix 源，改回 nuget.org（NativeAOT 需联网还原）
      nugetSetup = ''
        mkdir -p "$NUGET_PACKAGES" "$HOME/.nuget/NuGet"
        cat > "$HOME/.nuget/NuGet/NuGet.Config" <<'NUGETCFG'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" protocolVersion="3" />
  </packageSources>
</configuration>
NUGETCFG
      '';

      commonMeta = {
        platforms = [ "x86_64-linux" ];
      };

      # ── 1. 最小纯 LGPL·仅音频 FFmpeg ─────────────────────────────────────
      ffmpegMinimal = pkgs.stdenv.mkDerivation {
        pname = "archoera-ffmpeg-minimal";
        version = "9.0.1";
        # 只依赖构建脚本本身：编辑 flake 或其它源码都不改变 src 哈希。
        src = lib.cleanSourceWith {
          src = ./app/core;
          filter = path: type: baseNameOf path == "build-ffmpeg-minimal.sh";
        };
        nativeBuildInputs = with pkgs; [
          bash
          curl
          cacert
          nasm
          yasm
          pkg-config
        ];
        buildInputs = with pkgs; [
          libopus
          zlib
        ];
        dontConfigure = true;
        buildPhase = ''
          runHook preBuild
          export FFMPEG_PREFIX="$out"
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"
          export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
          bash build-ffmpeg-minimal.sh
          runHook postBuild
        '';
        dontInstall = true;
        meta = commonMeta // { description = "ArchoeraMusic minimal audio-only LGPL FFmpeg"; };
      };

      # ── 2. Zig 内核（静态库给引擎，动态库给 scanner）─────────────────────
      kernel = pkgs.stdenv.mkDerivation {
        pname = "archoera-kernel";
        inherit version;
        src = src;
        nativeBuildInputs = [ pkgs.zig ];
        dontConfigure = true;
        buildPhase = ''
          runHook preBuild
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"
          cd app/core/audio-engine
          # -Dcpu=baseline：内核按 x86-64 基线编译，避免构建机 AVX-512 生成
          # 的 EVEX 指令在普通用户 CPU 上 SIGILL（同 build-linux.sh）。
          zig build -Doptimize=ReleaseFast -Dcpu=baseline --prefix $out
          runHook postBuild
        '';
        dontInstall = true;
        meta = commonMeta // { description = "ArchoeraMusic Zig decode kernel"; };
      };

      # ── 3. audio-engine（C + CMake + Rust tempo，链接内核/FFmpeg）─────────
      audioEngine = pkgs.stdenv.mkDerivation {
        pname = "archoera-audio-engine";
        inherit version;
        src = src;
        nativeBuildInputs = with pkgs; [
          rustc
          cargo
          clang
          llvmPackages.libclang
          cmake
          ninja
          pkg-config
          git
          cacert
          curl
        ];
        buildInputs = with pkgs; [
          ffmpegMinimal
          libopus
          zlib
        ];
        strictDeps = false;
        dontConfigure = true;
        preBuild = netEnv;
        buildPhase = ''
          runHook preBuild
          set -euo pipefail
          mkdir -p app/core/audio-engine/zig-out
          cp -a ${kernel}/. app/core/audio-engine/zig-out/
          (
            cd app/core/audio-engine
            cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
            cmake --build build -j"$JOBS"
          )
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          mkdir -p $out
          cp -a app/core/audio-engine/build/archoera-audio-engine \
                app/core/audio-engine/build/libarchoera_mediaengine.so \
                app/core/audio-engine/build/libfft.so $out/
          cp -a app/core/audio-engine/build/ffmpeg $out/
          runHook postInstall
        '';
        meta = commonMeta // { description = "ArchoeraMusic audio engine"; };
      };

      # ── 4. scraper（C++ + CMake）─────────────────────────────────────────
      scraper = pkgs.stdenv.mkDerivation {
        pname = "archoera-scraper";
        inherit version;
        src = src;
        nativeBuildInputs = with pkgs; [ cmake ninja pkg-config ];
        buildInputs = with pkgs; [ taglib curl openssl sqlite nlohmann_json ];
        strictDeps = false;
        dontConfigure = true;
        buildPhase = ''
          runHook preBuild
          set -euo pipefail
          (
            cd app/core/scraper
            cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
            cmake --build build -j"$(nproc)"
          )
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          mkdir -p $out
          cp -a app/core/scraper/build/libarchoera_scraper.so $out/
          runHook postInstall
        '';
        meta = commonMeta // { description = "ArchoeraMusic metadata scraper"; };
      };

      # ── 5. scanner（.NET NativeAOT，内嵌内核动态库）──────────────────────
      scanner = pkgs.stdenv.mkDerivation {
        pname = "archoera-scanner";
        inherit version;
        src = src;
        nativeBuildInputs = with pkgs; [
          dotnet-sdk_10
          clang
          cacert
          curl
        ];
        buildInputs = with pkgs; [ zlib ];
        strictDeps = false;
        dontConfigure = true;
        dontConfigureNuget = true;
        preBuild = netEnv + nugetSetup;
        buildPhase = ''
          runHook preBuild
          set -euo pipefail
          mkdir -p app/core/audio-engine/zig-out
          cp -a ${kernel}/. app/core/audio-engine/zig-out/
          (
            cd app/core/scanner
            dotnet publish scanner-ffi/scanner-ffi.csproj -c Release -r linux-x64 -o build/publish
            cp build/publish/scanner-ffi.so build/
            cp build/publish/libe_sqlite3.so build/
            cp ../audio-engine/zig-out/lib/libarchoera_kernel.so build/
          )
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          mkdir -p $out
          cp -a app/core/scanner/build/scanner-ffi.so \
                app/core/scanner/build/libarchoera_kernel.so \
                app/core/scanner/build/libe_sqlite3.so $out/
          runHook postInstall
        '';
        meta = commonMeta // { description = "ArchoeraMusic library scanner (NativeAOT)"; };
      };

      # ── 6. vault（.NET NativeAOT）────────────────────────────────────────
      vault = pkgs.stdenv.mkDerivation {
        pname = "archoera-vault";
        inherit version;
        src = src;
        nativeBuildInputs = with pkgs; [
          dotnet-sdk_10
          clang
          cacert
          curl
        ];
        buildInputs = with pkgs; [ zlib ];
        strictDeps = false;
        dontConfigure = true;
        dontConfigureNuget = true;
        preBuild = netEnv + nugetSetup;
        buildPhase = ''
          runHook preBuild
          set -euo pipefail
          (
            cd app/core/vault
            dotnet publish src/Vault.csproj -c Release -r linux-x64 -o build/publish
            cp build/publish/archoera-vault build/
          )
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          mkdir -p $out
          cp -a app/core/vault/build/archoera-vault $out/
          runHook postInstall
        '';
        meta = commonMeta // { description = "ArchoeraMusic credential vault (NativeAOT)"; };
      };

      # ── 7. downloader（Rust cdylib）──────────────────────────────────────
      downloader = pkgs.stdenv.mkDerivation {
        pname = "archoera-downloader";
        inherit version;
        src = src;
        nativeBuildInputs = with pkgs; [
          rustc
          cargo
          git
          cacert
          curl
        ];
        strictDeps = false;
        dontConfigure = true;
        preBuild = netEnv;
        buildPhase = ''
          runHook preBuild
          set -euo pipefail
          cargo build --release --manifest-path app/core/downloader/Cargo.toml
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          mkdir -p $out
          cp -a app/core/downloader/target/release/libarchoera_downloader.so $out/
          runHook postInstall
        '';
        meta = commonMeta // { description = "ArchoeraMusic downloader (Rust)"; };
      };

      # ── 8. subsonic（Go c-shared + Rust 转码器）──────────────────────────
      subsonic = pkgs.stdenv.mkDerivation {
        pname = "archoera-subsonic";
        inherit version;
        src = src;
        nativeBuildInputs = with pkgs; [
          go
          rustc
          cargo
          clang
          git
          cacert
          curl
          pkg-config
        ];
        strictDeps = false;
        dontConfigure = true;
        preBuild = netEnv;
        buildPhase = ''
          runHook preBuild
          ( cd app/core/subsonic && bash build.sh )
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          mkdir -p $out
          cp -a app/core/subsonic/build/. $out/
          runHook postInstall
        '';
        meta = commonMeta // { description = "ArchoeraMusic subsonic server (Go + Rust)"; };
      };

      # ── 9. platform bridge（C++ + CMake，dbus）───────────────────────────
      platform = pkgs.stdenv.mkDerivation {
        pname = "archoera-platform";
        inherit version;
        src = src;
        nativeBuildInputs = with pkgs; [ cmake ninja pkg-config ];
        buildInputs = with pkgs; [ dbus systemd ];
        strictDeps = false;
        dontConfigure = true;
        buildPhase = ''
          runHook preBuild
          set -euo pipefail
          (
            cd app/native/platform
            cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
            cmake --build build -j"$(nproc)"
          )
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          mkdir -p $out
          cp -a app/native/platform/build/out/. $out/
          runHook postInstall
        '';
        meta = commonMeta // { description = "ArchoeraMusic platform bridge"; };
      };

      # ── 10. Flutter 应用 + 组装 ──────────────────────────────────────────
      archoera-music = pkgs.stdenv.mkDerivation {
        pname = "archoera-music";
        inherit version;
        src = src;

        nativeBuildInputs = with pkgs; [
          flutter
          clang
          cmake
          ninja
          pkg-config
          # app/linux/CMakeLists.txt 内嵌构建链：cargo（downloader）、
          # cmake 目标 audio_engine_cmake / subsonic_go 会在 Flutter 构建期重编
          # audio-engine 与 subsonic，故需 zig / go / rust 工具链与 FFmpeg。
          zig
          go
          rustc
          cargo
          autoPatchelfHook
          patchelf
          makeWrapper
          git
          cacert
          curl
        ];
        buildInputs = with pkgs; [
          ffmpegMinimal
          libopus
          gtk3
          glib
          libayatana-appindicator
          libepoxy
          fontconfig
          fribidi
          libX11
          libXi
          libXcursor
          libXrandr
          libXinerama
          libXcomposite
          libXdamage
          libXext
          libxcb
          libxkbcommon
          wayland
          libdrm
          at-spi2-atk
          libcloudproviders
          alsa-lib
          libpulseaudio
          libGL
          xz
          libunwind
          zlib
        ];

        strictDeps = false;
        dontConfigure = true;
        preBuild = netEnv;

        buildPhase = ''
          runHook preBuild
          set -euo pipefail
          # 关掉 Flutter 进度 spinner，便于看真实错误
          export CI=true
          export TERM=dumb

          # 放回原生模块产物（Flutter 的 linux/CMakeLists 从 core/*/build 安装；
          # downloader 由 Flutter 的 CMake 内嵌 cargo 构建，无需预置）
          mkdir -p app/core/audio-engine/build app/core/audio-engine/zig-out \
            app/core/scanner/build app/core/scraper/build app/core/subsonic/build \
            app/core/vault/build app/native/platform/build/out
          cp -a ${audioEngine}/. app/core/audio-engine/build/
          cp -a ${kernel}/. app/core/audio-engine/zig-out/
          cp -a ${scanner}/. app/core/scanner/build/
          cp -a ${scraper}/. app/core/scraper/build/
          cp -a ${subsonic}/. app/core/subsonic/build/
          cp -a ${vault}/. app/core/vault/build/
          cp -a ${platform}/. app/native/platform/build/out/
          # cp -a 从只读 Nix store 拷贝会把目标目录也设成只读，导致 CMake 目标
          # （audio_engine_cmake / subsonic_go）无法创建 pkgRedirects → 递归加写权限。
          chmod -R u+w app/core/audio-engine app/core/scanner app/core/scraper \
            app/core/subsonic app/core/vault app/native/platform

          echo "==> flutter build linux"
          (
            cd app
            flutter config --no-analytics || true
            flutter pub get
            flutter build linux --release > "$TMPDIR/flutter-build.log" 2>&1 || {
              echo "===== FLUTTER BUILD LOG ====="
              cat "$TMPDIR/flutter-build.log"
              echo "===== END ====="
              exit 1
            }
          )
          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          APP_ID="awa.archoera.betastudio2.archoera_music"

          mkdir -p $out/lib/archoera-music $out/bin \
            $out/share/applications $out/share/icons/hicolor/512x512/apps \
            $out/share/metainfo
          cp -r app/build/linux/x64/release/bundle/. $out/lib/archoera-music/
          chmod +x $out/lib/archoera-music/archoera_music
          makeWrapper $out/lib/archoera-music/archoera_music $out/bin/archoera-music

          sed "s|@EXEC@|archoera-music %U|g" \
            packaging/linux/archoera-music.desktop.in \
            > $out/share/applications/$APP_ID.desktop
          sed "s|@VERSION@|${version}|g" \
            packaging/linux/awa.archoera.betastudio2.archoera_music.metainfo.xml.in \
            > $out/share/metainfo/$APP_ID.metainfo.xml
          install -Dm644 app/linux/runner/resources/app_icon_512.png \
            $out/share/icons/hicolor/512x512/apps/$APP_ID.png

          # 去掉构建期 RPATH（/tmp/nix-build-*），保留 $ORIGIN 与 store 路径；
          # 否则 Nix fixup 的 forbidden-RPATH 校验直接失败。
          find $out -type f -print0 2>/dev/null | while IFS= read -r -d ''' f; do
            cur=$(patchelf --print-rpath "$f" 2>/dev/null) || continue
            case "$cur" in *nix-build*) ;; *) continue ;; esac
            new=$(printf '%s' "$cur" | tr ':' '\n' \
              | grep -v "^$TMPDIR" | grep -v '^/tmp/nix-build' | paste -sd: -)
            [ -z "$new" ] && new='$ORIGIN'
            patchelf --set-rpath "$new" "$f" 2>/dev/null || true
          done
          runHook postInstall
        '';

        meta = with lib; {
          description = "开源、多端、面向本地与在线音乐的混合架构播放器";
          homepage = "https://github.com/BetaStudio2/ArchoeraMusic";
          license = licenses.agpl3Only;
          mainProgram = "archoera-music";
          platforms = [ "x86_64-linux" ];
        };
      };
    in
    {
      packages.${system} = {
        default = archoera-music;
        archoera-music = archoera-music;
        inherit
          ffmpegMinimal
          kernel
          audioEngine
          scraper
          scanner
          vault
          downloader
          subsonic
          platform
          ;
      };
    };
}
