# 平台桥接本地交叉验证（Linux 主机）

`app/native/platform` 的桥接在三端各自**原生**构建（CI：Linux / Windows / macOS
runner）。本页说明如何在 **Linux 主机**上快速验证 Windows / macOS 后端能否通过
编译与链接，无需真机——用于改完桥接后的本地回归。

> 脚本只做验证，**不改动仓库产物**：对象/dylib 输出到临时目录
> （可用 `ARCHOERA_VERIFY_BUILD=<dir>` 指定保留位置）。

## 脚本一览

| 脚本 | 目标 | 依赖 |
|---|---|---|
| `app/tool/verify_windows.sh` | 用 msvc-wine 以 MSVC 编译 `backend_windows.cpp`（`/c`，不链接） | `/opt/msvc`（msvc-wine）、`wine` |
| `app/tool/verify_macos.sh` | 用 clang 交叉编译 + 链接 `backend_macos.mm`（arm64 / x86_64 dylib） | `clang++`、`ld64.lld`、macOS SDK |
| Linux 端 | 直接原生构建（无需脚本） | `flutter build linux` / cmake，见 `AGENTS.md` |

---

## Windows（msvc-wine）

用 [msvc-wine](https://github.com/mstorsjo/msvc-wine) 在 Linux 上跑 MSVC `cl.exe`。

**安装**（示例，路径可自定义）：

```bash
git clone https://github.com/mstorsjo/msvc-wine
cd msvc-wine
./vsdownload.py --accept-license --dest /opt/msvc
./install.sh /opt/msvc
# 另需 wine（Arch: sudo pacman -S wine）
```

**验证**：

```bash
bash app/tool/verify_windows.sh
# 或指定安装位置：
MSVC_INSTALL_DIR=/opt/msvc bash app/tool/verify_windows.sh
```

脚本用项目同款标志编译 `core.cpp` / `apl.cpp` / `backend_windows.cpp`：
`/std:c++20 /EHsc /O2 /W3 /permissive- /Zc:__cplusplus /utf-8`，并自动探测
cppwinrt 头（存在则一并编译 WinRT/SMTC/Toast 分支，缺省自动降级）。

> `/utf-8` 必需：源文件含 UTF-8 中文注释，MSVC 默认按系统代码页（如 936）
> 解析会报 `C4819` 并连带解析错乱。项目 `CMakeLists.txt` 已设置该项。

---

## macOS（clang 交叉编译）

macOS 后端直接 `#import` AppKit / Foundation / MediaPlayer / UserNotifications
并链接框架，因此需要**完整 macOS SDK**（Zig 自带 SDK 不含框架头）。

**安装 SDK**（约 67MB，仅本地构建用途）：

```bash
bash app/tool/verify_macos.sh --download
```

等价手动步骤：

```bash
mkdir -p ~/.local/share/macos-sdk && cd ~/.local/share/macos-sdk
curl -sL -o MacOSX14.0.sdk.tar.xz \
  https://github.com/joseluisq/macosx-sdks/releases/download/14.0/MacOSX14.0.sdk.tar.xz
tar xf MacOSX14.0.sdk.tar.xz && rm MacOSX14.0.sdk.tar.xz
```

**验证**：

```bash
bash app/tool/verify_macos.sh              # arm64 + x86_64
bash app/tool/verify_macos.sh --arch arm64 # 单架构
ARCHOERA_MACOS_SDK=/path/MacOSX.sdk bash app/tool/verify_macos.sh
```

脚本用 `clang++ -target <arch>-apple-macos14.0 -isysroot <SDK>` 编译
`core.cpp` / `apl.cpp` / `backend_macos.mm`（ObjC++，`-fobjc-arc`），再用
`-fuse-ld=lld`（`ld64.lld`）+ 框架链接成 dylib，并抽查 `apl_*` 导出符号。

SDK 查找顺序：`--sdk` / `ARCHOERA_MACOS_SDK` → `~/.local/share/macos-sdk/MacOSX14.0.sdk`
→ 该目录下任意 `MacOSX*.sdk`。

---

## 说明与边界

- **许可**：macOS SDK 为 Apple 许可，仅用于本地构建，存放于 `~/.local/share/macos-sdk/`，
  **不入库**、不随发布分发。做法与 osxcross 一致。
- **不等同真机**：本页工具只验证「能否编译/链接」。运行期行为（媒体会话、系统色、
  窗口状态等）仍需各平台真机/CI 验证。
- **CI 不变**：正式产物仍由 `.github/workflows/build-all.yml` 在三端 runner 原生构建；
  本页工具仅用于本地快速回归。
