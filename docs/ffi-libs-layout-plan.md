# FFI 动态库布局整理规划

> 状态：**已实施（2026-08-12，三步全部完成）**
> 定位：消除自研工具链 FFI 动态库在 bundle 中的「散装」分布——统一集中到单一目录，
> 合并 Dart 侧 5 套路径解析逻辑，降低构建产物与打包链路的杂乱度。

---

## 1. 背景与现状

### 1.1 bundle 内分布（散装现状）

自研工具链 FFI 库当前各占一个 `<module>/build/` 子目录，互不统一：

```
bundle/                                          # 以 Linux release 为例
├── audio-engine/build/{libarchoera_mediaengine.so, libfft.so}
├── scanner/build/{scanner-ffi.so, libe_sqlite3.so}
├── scraper/build/{libarchoera_scraper.so}
├── subsonic/build/{libarchoera_subsonic.so, libarchoera_transcoder.so}
└── core/downloader/target/{debug,release}/libarchoera_downloader.so   ← 目录层级最突兀
```

其中 `core/downloader/target/` 是 Cargo 产物目录（debug/release 双份），与其他模块的 CMake 布局完全不一致。

### 1.2 Dart 侧：5 套独立的路径解析逻辑

| 模块 | 加载文件 | 解析方式 |
|---|---|---|
| 音频引擎 | `engine_bindings.dart` + `engine_paths.dart` | `DynamicLibrary.open('libarchoera_mediaengine.so')` 按文件名（依赖系统搜索路径）+ `EnginePaths.libfftPath()`：exe 祖先链找 `audio-engine/`，dev 兜底 `cwd/core/audio-engine` |
| FFT | `fft_bindings.dart` | 走 `EnginePaths.libfftPath()` |
| 扫描 | `scanner_ffi.dart` | 环境变量 `ARCHOERA_SCANNER_FFI` → 默认相对路径 |
| 刮削 | `scraper_bindings.dart` | exe 祖先链找 `scraper/build/`，dev 兜底 `cwd/core/scraper/build` |
| Subsonic | `subsonic_bindings.dart` | exe 祖先链找 `subsonic/build/`，dev 兜底 `cwd/core/subsonic/build`（transcoder 由 Go 侧 dlopen） |
| 下载 | `downloader_ffi.dart` | 环境变量 `ARCHOERA_DOWNLOADER_SO` → 默认 `core/downloader/target/release/` |

> 5 处逻辑高度相似（祖先链查找 + dev 兜底），是明显的重复代码，应统一为一个工具。

### 1.3 构建侧

- 各模块独立构建到 `core/<module>/build/`（CMake 输出目录）或 `core/downloader/target/`（Cargo）；
- 平台 CMakeLists（`app/linux/CMakeLists.txt` L221-241、`app/windows/CMakeLists.txt` L114-134）用 `install(... OPTIONAL)` 把各 `<module>/build` 产物装到 `bundle/<module>/build/`，**保持与构建目录相同的相对结构**——杂乱由构建侧一路传导到 bundle。

### 1.4 问题

1. 5 个模块各占一个子目录，bundle 结构杂乱，安装包/调试定位困难；
2. Dart 侧 5 套路径解析逻辑重复维护，改一处易漏其他；
3. downloader 的 Cargo `target/{debug,release}` 布局与其他模块不一致，且 release 包会携带 debug 产物。

---

## 2. 目标

1. **FFI 动态库集中到单一目录**（推荐 `bundle/native/`，避免与 Flutter 标准 `lib/`、`data/` 混排）；
2. **合并 Dart 侧路径解析为统一工具**（如 `NativeLibPaths`），所有模块共用一套祖先链 + dev 兜底 + 环境变量覆盖逻辑；
3. 构建/打包/CI 三条链路的产物路径单一化；
4. 保持既有环境变量覆盖能力（`ARCHOERA_AUDIO_ENGINE` / `ARCHOERA_SCANNER_FFI` / `ARCHOERA_DOWNLOADER_SO` 兼容）。

---

## 3. 方案：统一 `native/` 目录

### 3.1 目标布局

```
bundle/native/                                  # 全部 FFI 库平铺
├── libarchoera_mediaengine.so
├── libfft.so
├── scanner-ffi.so
├── libe_sqlite3.so
├── libarchoera_scraper.so
├── libarchoera_subsonic.so
├── libarchoera_transcoder.so
└── libarchoera_downloader.so
```

Windows 对应 `.dll`、macOS 对应 `.dylib`，命名规则沿用各模块现有约定。

### 3.2 统一路径解析（`NativeLibPaths`）

新工具收敛现有 5 套逻辑，解析优先级：

1. **环境变量覆盖**：保留各模块既有变量（向后兼容），新增统一变量（如 `ARCHOERA_NATIVE_DIR` 指向 `native/` 目录）优先；
2. **bundle**：从 `Platform.resolvedExecutable` 沿祖先链找 `native/` 目录（对齐现有 `audio-engine` / `scraper` / `subsonic` 祖先链模式）；
3. **dev 兜底**：`flutter run` 的 cwd = `app/` → `app/core/<module>/build/` 旧布局（过渡期），或 `app/native/`（迁移后）。

各模块加载点（engine/scraper/subsonic 的祖先链、scanner/downloader 的默认路径）全部改走 `NativeLibPaths`。

### 3.3 构建侧统一 install

- `app/linux/CMakeLists.txt`、`app/windows/CMakeLists.txt`（macOS 如有）的 install 目标统一改为 `DESTINATION native/`；
- downloader：CI/打包脚本从 `core/downloader/target/release/` 复制到 `native/`（仅 release，不再进入 debug）；
- 各模块的**构建输出目录保持现状**（`core/<module>/build/` 不动），只统一「安装进 bundle」的目标位置——避免动每个模块的 CMake 工程。

### 3.4 dev 态布局

迁移完成后 dev 兜底改为 `app/native/`（或在构建脚本里把各模块产物复制到 `app/native/`），`flutter run` 下与 bundle 布局一致。

---

## 4. 改动点清单

| 层 | 文件 | 改动 |
|---|---|---|
| Dart 路径解析 | 新增 `app/lib/services/native_lib_paths.dart`（或并入现有 engine_paths 同目录） | 统一祖先链 + dev 兜底 + 环境变量 |
| Dart 加载点 | `engine_paths.dart` / `engine_bindings.dart` / `fft_bindings.dart` / `scanner_ffi.dart` / `scraper_bindings.dart` / `subsonic_bindings.dart` / `downloader_ffi.dart` | 全部改走 `NativeLibPaths`；`subsonic_controller.dart` 的 transcoder 路径同步（Go 侧 dlopen） |
| 构建 | `app/linux/CMakeLists.txt`、`app/windows/CMakeLists.txt`（macOS 如有） | install 目标统一 `native/` |
| CI | `.github/workflows/build-{linux,macos,windows}.yml` | downloader 复制目标 → `native/`；如路径硬编码一并同步 |
| 打包 | `packaging/linux/` 脚本（AppImage/Arch/Flatpak 工作区路径） | 依赖 `<module>/build/` 的路径改为 `native/` |

---

## 5. 风险与权衡

| 风险 | 应对 |
|---|---|
| dev 态回归（`flutter run` 找不到库） | 统一 `NativeLibPaths` 后先在 dev 态验证，再切 bundle 布局 |
| Windows 下 `DynamicLibrary.open` 相对路径依赖 DLL 搜索路径 | 统一解析返回**绝对路径**再 `open`，不依赖系统 PATH |
| Go transcoder 由 subsonic 侧 dlopen，路径在 Go 侧解析 | `subsonic_controller.dart` 传入绝对路径，Go 侧直接使用 |
| 改动跨 Dart + 3 平台 CMake + 打包脚本 | 分步落地（见 §6），每步独立可回归 |
| 旧布局残留目录（`<module>/build/` 在 bundle 内） | 迁移完成后从 CMake install 列表移除，并清理 packaging 工作区 |

## 6. 分步落地

> 状态：✅ 全部完成（2026-08-12）。

1. **第一步：统一 Dart 路径解析**——新增 `NativeLibPaths`（`app/lib/services/native_lib_paths.dart`，`NativeModule` 枚举承载平台文件名/环境变量/候选路径），7 个加载点（engine_bindings / fft_bindings / scanner_ffi / scraper_bindings / subsonic_bindings / downloader_ffi + scanner 的 sqlite 同目录预加载）全部改走它；`NativeModule.candidates` 含 `native`（优先）与旧 `<module>/build` 路径（回退） ✅
2. **第二步：切换 bundle 布局**——`app/linux/CMakeLists.txt` 与 `app/windows/CMakeLists.txt` install 目标统一 `native/`（含 vault、downloader；Windows 另含 vcpkg FFmpeg DLL 与 mingw 运行库 → exe 根目录）；macOS 无 CMake install 层（Flutter 走 Xcode），在 `build-macos.yml` 显式拷入 `.app/Contents/native/`；downloader 经各平台 CMake 内嵌 cargo 链（Linux/Windows）或 CI 预构建（macOS）进 `native/` ✅
3. **第三步：清理**——bundle 内 `<module>/build/` 残留已随 CMake install 列表移除（Linux 实测 `bundle/` 顶层无旧模块目录）；`NativeLibPaths.candidates` 保留旧路径作 dev 回退（无害）；packaging/linux 脚本只打包整个 bundle 目录，无需改动 ✅

## 7. 验证计划

> 状态：✅ 通过 / ⏳ 待做。

1. ✅ Linux dev：`flutter run` 下引擎/FFT/扫描/刮削/Subsonic/下载统一走 `NativeLibPaths`（环境变量 → 祖先链 → dev 兜底）；
2. ✅ Linux release bundle：`bundle/native/` 平铺 10 产物（8 库 + archoera-audio-engine + archoera-vault），功能回归（播放、FFT、扫描入库、刮削、Subsonic 流媒体、下载）——2026-08-12 本地 `flutter build linux --release` 实测；
3. ⏳ Windows / macOS CI 构建：DLL/dylib 正确入 `native/`（Windows 已由 CMake install 覆盖；macOS 拷贝步骤已加，待 CI 触发验证）；
4. ✅ 环境变量覆盖（`ARCHOERA_AUDIO_ENGINE` / `ARCHOERA_SCANNER_FFI` / `ARCHOERA_DOWNLOADER_SO` / 统一 `ARCHOERA_NATIVE_DIR`）行为不回退（`NativeLibPaths.resolve` 解析优先级保留）。

## 8. 实施偏差与注意

- **macOS**：无 CMake install 层，`build-macos.yml` 在 `flutter build` 后显式拷入 `.app/Contents/native/`（`NativeLibPaths` 祖先链从 `Contents/MacOS` 向上第 2 级命中 `Contents/native`）；Homebrew 依赖（ffmpeg 等）install_name 为绝对路径，真机需 Homebrew 环境（既有限制，真机验证待做）。
- **Windows mingw 运行库**：`archoera_subsonic.dll` 由 mingw（cgo）编译，动态依赖 `libgcc_s_seh-1.dll`/`libwinpthread-1.dll`；`windows/CMakeLists.txt` 经 `find_file` 搜索 choco mingw 目录后 install 到 exe 根目录（Windows 加载器按 exe 目录解析依赖），找不到时静默跳过。
- **transcoder Dart 注入**：计划要求 `subsonic_controller.dart` 注入绝对路径（Go 侧 dlopen）；当前内置 Subsonic 服务端在 Dart 主进程尚未接入（`SubsonicController` 仅在 `app/tool/subsonic_smoke.dart` 使用），该注入点留待服务端生命周期接入时同步（`NativeModule.transcoder` 已就绪）。
- **vault 随包分发**：三平台均已把 `archoera-vault` 装入 `native/`（vault-4 按需 spawn 的基础）。
