# 三端打包与产物说明

本文是**发布产物的唯一对照表**：每个平台产出什么、由谁生成、文件名长什么样、
用户拿到后怎么装。构建与签名流程见 [AGENTS.md §发布与签名](../AGENTS.md)，
Linux 依赖门禁见 [release-dependency-guard.md](release-dependency-guard.md)。

## 1. 总览

| 平台 | 产物 | 入口脚本 / 配置 | 命名 |
|---|---|---|---|
| Linux | `.deb`（Ubuntu 24.04 / Deepin 25） | `packaging/linux/package.sh deb` | `ArchoeraMusic-<ver>-ubuntu24.04-x86_64.deb`、`-deepin25-x86_64.deb` |
| Linux | `.rpm`（Fedora/openSUSE 系） | `packaging/linux/package.sh rpm` | `ArchoeraMusic-<ver>-fedora-x86_64.rpm` |
| Linux | `pkg.tar.zst`（Arch/Manjaro） | `packaging/linux/package.sh arch` → `PKGBUILD` | `ArchoeraMusic-<ver>-arch-x86_64.pkg.tar.zst` |
| Linux | `.AppImage`（通用便携） | `packaging/linux/package.sh appimage` | `ArchoeraMusic-<ver>-x86_64.AppImage` |
| Linux | `.flatpak` | `packaging/linux/package-flatpak.sh` | `ArchoeraMusic-v<ver>-flatpak-x86_64.flatpak` |
| Linux | NixOS flake 源构建产物 | `packaging/linux/nix/package.nix` | `ArchoeraMusic-<ver>-nixos-x86_64.tar.gz` |
| macOS | **`.dmg`（拖拽安装）** | `packaging/macos/package.sh` | `ArchoeraMusic-<ver>-macos-<arm64\|x64>.dmg` |
| macOS | `.zip`（便携） | 同上 | `ArchoeraMusic-<ver>-macos-<arm64\|x64>.zip` |
| Windows | **Inno Setup 安装器** | `packaging/windows/archoera_music.iss` | `ArchoeraMusic-<ver>-windows-x64-setup.exe` |
| Windows | 便携 zip | workflow 内 `Compress-Archive` | `ArchoeraMusic-<ver>-windows-x64-portable.zip` |

所有资产在 release 作业里由 `app/tool/sign_release.sh` 逐个生成 `<asset>.sig1`
（ECDSA P-256 / SHA-256），并汇总为 `SHA256SUMS`；另有 `ARCHOERA-SBOM.cdx.json`
与构建溯源 attestation。

## 2. Linux

**统一入口** `packaging/linux/package.sh <格式> <bundle> <版本>`。任何格式在
开头都会先跑 `app/tool/check_bundle_deps.sh`（NEEDED / `$ORIGIN` / 内嵌库实际
解析位置 / `libssl`·`libcrypto`·`libcurl` 禁止项），不通过直接失败。

各格式要点：

- **deb / rpm**：`/opt/archoera-music` 整目录安装 + `/usr/bin` 符号链接；
  `Depends`/`Requires` 只列 ABI 稳定的系统库（GTK3、DBus、SQLite、X11 等）。
  包内 `BUILD-INFO.txt` 写明构建目标、基线、最低 glibc 与提交。
- **arch**：`package.sh` 只预置工作目录，`makepkg` 在 archlinux 容器里执行。
- **AppImage**：linuxdeploy 收拢依赖；runner 的 `DT_NEEDED` 之外，Dart 侧按名
  `dlopen` 的 Flutter 插件（`libcnativeapi.so` 等）也会显式 `--library`
  传入，否则打包后启动报 `cannot open shared object file`。
- **flatpak**：包装预构建 bundle（不源码构建），bundle 整体放 `/app`。
- **nix**：`package.sh nix` 预置 flake 工作目录，由 NixOS 环境 `nix build`。

`archoera_music` 自带 `archoerashell` 子命令（纯二进制 tar 与各包一致）。

## 3. macOS

由 `packaging/macos/package.sh` 生成（**必须在 macOS 上运行**）：

```bash
bash packaging/macos/package.sh <archoera_music.app> <版本> <arm64|x64>
```

- **`.dmg`**：`hdiutil -format UDZO -fs HFS+` 打包一个临时舞台目录，内容为
  `ArchoeraMusic.app` + `应用程序` → `/Applications` 的符号链接 +
  `首次打开说明.txt`。生成后会**挂载回读**校验
  `ArchoeraMusic.app/Contents/MacOS/archoera_music` 可执行；失败即删包报错。
- **`.zip`**：`ditto -c -k --sequesterRsrc --keepParent`，保留
  `Frameworks/FlutterMacOS.framework` 等符号链接与可执行位（普通 `zip`/`tar`
  会破坏链接结构）。
- 另外写 `*.info.txt`（bundle id / 版本 / 架构），便于下游核对。

**签名与公证**：当前**未做** Developer ID 签名与 Apple 公证（需付费证书）。
因此首次打开会触发 Gatekeeper 拦截，用户须右键「打开」或在「系统设置 →
隐私与安全性」点「仍要打开」——DMG 内已附说明。这属于已知限制，不视为打包
错误；`docs/supply-chain.md` 里登记为待办。

架构：arm64 与 x86_64 **分别构建、分别发包**，不做 universal（`native/` 下
FFmpeg、NativeAOT、Rust/Go 模块均为单架构）。部署目标 macOS 14.0。

## 4. Windows

- **安装器**（`archoera_music.iss`）：`PrivilegesRequired=lowest`，默认
  **per-user 免 UAC**；用户可在向导里主动选 per-machine（唯一允许提权的例外）。
  `Compression=lzma2/max`，`ArchitecturesAllowed=x64compatible`。
- **便携 zip**：runner `Release` 目录整体（含 `native/`、`data/`、插件 dll）。
- 防伪公钥 `ARCHOERA_PUBKEY.pem` 随包分发（私钥绝不入库/入包）。

## 5. 本地打包怎么验证

```bash
# Linux（本机 x64）
cd app && flutter build linux --release && cd ..
bash app/core/bundle-linux-runtime.sh app/build/linux/x64/release/bundle
bash app/tool/check_bundle_deps.sh   app/build/linux/x64/release/bundle
bash app/tool/smoke_start_linux.sh   app/build/linux/x64/release/bundle
DISTRO_TAG=ubuntu24.04 bash packaging/linux/package.sh deb \
  app/build/linux/x64/release/bundle 1.0.6
bash packaging/linux/package.sh appimage app/build/linux/x64/release/bundle 1.0.6
bash app/tool/smoke_start_linux.sh dist/linux/*.AppImage   # AppImage 冒烟

# macOS（需在 Mac 上）
bash app/core/build-macos.sh osx-arm64
cd app && flutter build macos --release && cd ..
bash packaging/macos/package.sh \
  "app/build/macos/Build/Products/Release/archoera_music.app" 1.0.6 arm64
hdiutil attach -nobrowse -readonly "dist/macos/ArchoeraMusic-1.0.6-macos-arm64.dmg"
```

CI 中 macOS 打包后会保留 DMG 与 zip 两个文件，`release` 作业直接作为独立资产
上传（不再 tar 目录）。

> 版本号取其**主版本段**（`app/pubspec.yaml` 的 `version: 1.0.6+4` → `1.0.6`），
> 与 Linux 包一致；Windows 文件名沿用完整版本串（`1.0.6+4`）。
