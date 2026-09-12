# 用户自编译手册（太长不看版 · 附详细步骤）

> **太长不看版**：装好 Flutter SDK + Zig 0.16 + Rust + Go + .NET 10 + CMake/Clang + FFmpeg 开发库后，
> 依次执行两行命令即可（Linux 为例）：
>
> ```bash
> bash app/core/build-linux.sh          # 1) 编译全部原生模块（audio-engine/FFT、scanner、scraper、vault、downloader、subsonic）
> cd app && flutter build linux --release   # 2) 编译 Flutter Release → app/build/linux/x64/release/bundle/
> ```
>
> 想直接本地调试：把第 2 步换成 `cd app && flutter run -d linux`。
> Windows 用 `app/core/build_windows.bat` + `flutter build windows`；macOS 用
> `bash app/core/build-macos.sh osx-arm64` + `flutter build macos`。
> 本手册从「为什么是这些前置」讲到「怎么排查」，想按部就班就从头往下读。

---

## 0. 总览：一次自编译到底编译了什么

本项目 UI 用 **Flutter（Dart）**，底层是多个**原生模块**，通过 FFI / 子进程直连，没有 sidecar
进程与本地端口：

| 模块 | 语言 | 产物 | 用途 |
|---|---|---|---|
| `audio-engine` | C / Zig 内核 | `archoera-audio-engine`、`libarchoera_mediaengine.so`、**`libfft.so`** | 解码→DSP（EQ/响度/限幅/FFT 频谱/变速）→Opus |
| `scanner` | C#（NativeAOT） | `scanner-ffi.so` + `libe_sqlite3.so` | 本地音乐库扫描建库 |
| `scraper` | C++ | `libarchoera_scraper.so` | 多源元数据刮削 + 仅目录整理 |
| `downloader` | Rust（cdylib） | `libarchoera_downloader.so` | Kugou / Netease 下载引擎 |
| `subsonic` | Go + Rust | `libarchoera_subsonic.so`、`libarchoera_transcoder.so` | 可选 Subsonic 服务端与转码器 |
| `vault` | C#（NativeAOT） | `archoera-vault` | 凭据保险库（2-of-2） |

> “FFT 部分”指 audio-engine 的 `libfft.so`（Dart 侧频谱分析用，纯 libm、无外部依赖）——
> 它在 `build-linux.sh` 里随 audio-engine 一起被 CMake 编译，无需单独步骤。

## 1. 前置环境

版本要求以 `app/core/build-linux.sh` 头注释与 `.github/workflows/build-all.yml` 为准：

- **Flutter SDK** `^3.12`（`cat app/pubspec.yaml | grep sdk` 查看精确约束）
- **Zig 0.16.x**：编译自研解码内核 EraAudio（`app/core/audio-engine/kernel/`）。缺 Zig 时脚本告警并回退
  FFmpeg/Stable 运行（EraAudio 不启用）；如需完整内核请安装 0.16。
- **CMake ≥ 3.16 + C 工具链**（GCC/Clang），用于 audio-engine / scraper
- **Rust 工具链**：tempo-rs（静态链接）、downloader、subsonic transcoder
- **Go 1.23+**：subsonic 服务端
- **.NET SDK 10**：scanner / vault 的 NativeAOT publish
- **FFmpeg 开发库**（`libavcodec`/`libavformat`/`libavutil`/`libswresample`）：
  - 本地开发可直接用系统 FFmpeg：
    - Debian/Ubuntu：`sudo apt install ffmpeg libavcodec-dev libavformat-dev libavutil-dev libswresample-dev`
    - Arch/EndeavourOS：`sudo pacman -S ffmpeg`（含开发头文件）
    - Fedora：`sudo dnf install ffmpeg-devel`
    - macOS：`brew install ffmpeg`
  - **发布/自包含构建（推荐，与 CI 一致）**：改用 `bash app/core/build-ffmpeg-minimal.sh`
    自建**最小纯 LGPL** FFmpeg，再 `export PKG_CONFIG_PATH=$HOME/.local/ffmpeg-minimal/lib/pkgconfig`。
    引擎只链自建库（内嵌后仅依赖 libc/libm/libz），跨发行版可运行，且满足 LGPL 合规。
    ⚠️ **不要用 Homebrew 的 ffmpeg**（默认 `--enable-gpl`，违反 `THIRD-PARTY-LICENSES.md` 的 GPL 防火墙）。
  - Windows：依赖由 `app/vcpkg.json` 经 vcpkg（manifest 模式）安装，`build_windows.bat` 里缺头文件会自动
    install（`VCPKG_TARGET_TRIPLET=x64-windows-release`）

校验是否齐全：

```bash
flutter --version && zig version && cargo --version && go version \
  && dotnet --list-sdks && cmake --version && pkg-config --modversion libavcodec
```

## 2. Linux 自编译（详细）

```bash
# 在仓库根目录执行
bash app/core/build-linux.sh
```

脚本按序做六件事（幂等，可重复执行；`set -euo pipefail`，任一步失败即退出并报错）：
1. **Zig EraAudio 内核**：`zig build -Doptimize=ReleaseFast`（输出 `audio-engine/zig-out/` 与本地缓存
   `.zig-cache/`；内核改动后必须先重跑本步，否则链接陈旧产物）
2. **audio-engine（含 libfft.so）**：`cmake -S ... -B audio-engine/build -DCMAKE_BUILD_TYPE=Release` +
   `cmake --build`
3. **scraper（C++）**：同上 CMake 构建 `libarchoera_scraper.so`
4. **scanner（C# NativeAOT）**：`bash app/core/scanner/build.sh linux-x64`（产出
   `scanner/build/scanner-ffi.so` + `libe_sqlite3.so`）
5. **vault（C# NativeAOT）**：`bash app/core/vault/build.sh linux-x64`
6. **downloader（Rust）**：`cargo build --release`；**subsonic**：`bash app/core/subsonic/build.sh`
   （cargo transcoder + go c-shared + go standalone）

随后编译 Flutter 端：

```bash
cd app
flutter pub get          # 首次或依赖变更后
dart analyze lib         # 可选：静态检查
flutter build linux --release
```

**产物位置**：`app/build/linux/x64/release/bundle/`
- `archoera_music`（可执行文件）
- `data/`（Flutter assets + icudtl）
- `native/`：上表全部原生产物平铺（CMake 在构建时自动从各模块 `build/` 拷入）。发布构建另用
  `bash app/core/bundle-linux-runtime.sh app/build/linux/x64/release/bundle/native` 把 FFmpeg/TagLib 的
  传递依赖闭包收进此处并加 `RUNPATH=$ORIGIN`，使产物不依赖目标发行版 soname；包内 `BUILD-INFO.txt`
  记录构建目标/基线/最低 glibc。

直接跑：
```bash
./app/build/linux/x64/release/bundle/archoera_music
```
开发调试（热重载、控制台日志）：
```bash
cd app && flutter run -d linux
```

## 3. Windows 自编译（详细）

前置：Visual Studio（含 C++ 桌面负载，提供 MSVC 与 `vcvars64`）、CMake、Rust、Go、.NET 10、Flutter，
并在 `app/` 目录准备 vcpkg（默认 `C:\vcpkg`，可设 `VCPKG_ROOT`）。

```cmd
cd app\core
build_windows.bat            :: MSVC 环境 + 各模块一站式构建
cd ..\..
cd app
flutter pub get
flutter build windows
```
产物：`app/build/windows/x64/runner/Release/`；运行需要 `native/` 平铺库时，`flutter run`/`build` 会自动处理。

## 4. macOS 自编译（详细）

```bash
bash app/core/build-macos.sh osx-arm64   # Apple Silicon；Intel 用 x86_64-apple-darwin 之类（见脚本头）
cd app && flutter build macos --release
```
Flutter 构建后会把各模块 `*.dylib` 拷入 `.app/Contents/native/`（macOS 无 CMake install 层，见
`linux/CMakeLists.txt` 对应注释）。macOS 产物未签名，首次运行需右键“打开”或
`xattr -dr com.apple.quarantine ArchoeraMusic.app`。

## 5. 缓存外置（可选，避免污染仓库 / 提速）

把 Rust / Zig 等缓存放到仓库外，避免在 `app/core/**` 内留下大目录，也便于多个本地构建共享：

```bash
mkdir -p ~/.cache/archoera-local/{cargo-target,zig-global}
export CARGO_TARGET_DIR="$HOME/.cache/archoera-local/cargo-target"
export ZIG_GLOBAL_CACHE_DIR="$HOME/.cache/archoera-local/zig-global"
bash app/core/build-linux.sh
```

> 注意：`flutter build linux` 内部的 downloader / subsonic 内嵌 cargo 步骤会按模块默认
> `target/` 路径取产物（见 `app/linux/CMakeLists.txt`），执行 Flutter 构建前请 **`unset CARGO_TARGET_DIR`**，
> 否则该步骤产物会落到外部目录导致拷贝失败。

## 6. 打安装包（Linux）

打包入口 `packaging/linux/package.sh`（bundle 必须保持完整目录结构）：

```bash
BUNDLE="$PWD/app/build/linux/x64/release/bundle"
VERSION=0.9.11+5     # 以 app/pubspec.yaml 的 version 为准
bash packaging/linux/package.sh tar    "$BUNDLE" "$VERSION"   # 纯二进制 .tar.gz
bash packaging/linux/package.sh deb    "$BUNDLE" "$VERSION"   # Debian/Ubuntu
bash packaging/linux/package.sh rpm    "$BUNDLE" "$VERSION"   # Fedora/RHEL
bash packaging/linux/package.sh appimage "$BUNDLE" "$VERSION" # AppImage
bash packaging/linux/package-flatpak.sh "$BUNDLE" "$VERSION"  # Flatpak
```

**AUR / Arch（本地 makepkg）**：预置工作目录后在 Arch 系系统直接 makepkg（等效 CI 的容器流程）：

```bash
bash packaging/linux/package.sh arch "$BUNDLE" "$VERSION"     # 生成 packaging/linux/work/arch/
cd packaging/linux/work/arch
makepkg -f --skipinteg --nocheck --nodeps                      # 产出 *.pkg.tar.zst
```
其它发行版详见 `.github/workflows/build-all.yml` 的 Linux 打包链（deb→rpm→AppImage→flatpak→nix→arch）。

## 7. 常见问题排查

- **找不到原生库**（如 `ARCHOERA_SCANNER_FFI` / `ARCHOERA_SCRAPER_FFI` 相关报错）：说明 `native/`
  平铺库缺失或路径未命中。本地跑请先完成第 2 步再 `flutter run`；发布包内库在 `bundle/native/`。
  排查可设 `ARCHOERA_NATIVE_DIR` 指向库目录。
- **EraAudio 未启用**：`command -v zig` 为空或版本非 0.16 → 装好 0.16 后重跑
  `app/core/build-linux.sh`（它会先编译 Zig 内核）。
- **audio-engine CMake 找不到 FFmpeg**：确认 `pkg-config --modversion libavcodec` 能查到——用系统
  FFmpeg 时装其开发库；用自建最小 FFmpeg 时确认已 `export PKG_CONFIG_PATH=$HOME/.local/ffmpeg-minimal/lib/pkgconfig`。
  构建时会把所用 FFmpeg 运行库拷进 `audio-engine/build/ffmpeg/`（发布构建再由 `bundle-linux-runtime.sh` 收拢闭包）。
- **scanner / vault NativeAOT 慢**：正常（全量 publish 需数分钟）；改 C# 后可用
  `dotnet build` 快速验证语法再跑 `build.sh`。
- **Rust 首次编译慢 / 网络差**：依赖已进本地 `~/.cargo` registry；如需离线可对相应 crate 目录
  执行 `cargo vendor`（见 `docs/download-module.md` §9.6）。
- **AUR makepkg 失败**：确认在 `packaging/linux/work/arch/` 内、`bundle.tar.zst` 存在、非 root 用户
  执行；跳过依赖检查用 `--nodeps`。
- **本手册不是法律意见**：源码分发、第三方许可与授权边界详见根 `LICENSE`、各模块
  `THIRD-PARTY-LICENSES.md` 与 README「使用声明」。

## 8. 相关文件速查

| 需要 | 看哪里 |
|---|---|
| 各模块一键编译入口 | `app/core/build-linux.sh`、`app/core/build-macos.sh`、`app/core/build_windows.bat` |
| Flutter Linux 构建与 native 拷贝 | `app/linux/CMakeLists.txt` |
| Zig 内核路线图 | `docs/audio-kernel-zig.md` |
| FFmpeg 依赖版本与许可 | `app/core/audio-engine/THIRD-PARTY-LICENSES.md` |
| CI 全流程（三端 + 打包） | `.github/workflows/build-all.yml` |
