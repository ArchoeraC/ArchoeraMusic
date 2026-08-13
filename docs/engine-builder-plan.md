# 音频引擎自编译框架规划（Engine Builder Plan）

> 状态：**规划中（仅记入计划，未实施）**
> 定位：为音频引擎建立「着色器编译」式的即时自编译能力——应用自带 tcc 编译器与
> FFmpeg 头文件，运行时按系统 FFmpeg 版本指纹自动重编引擎，用户机器零工具链依赖。
> 与 0d5b65c 内嵌 FFmpeg 运行库方案共存：内嵌库是兜底，自编译是增强。

---

## 1. 背景与痛点

### 1.1 核心问题：系统 FFmpeg major 升级破坏引擎

- 引擎（`audio-engine`）动态链接系统 FFmpeg（`libavformat/libavcodec/libavutil/libswresample`），
  soname 带 major 版本号（`.so.60/.61/.62/.63` 对应 FFmpeg 6/7/8/9）；
- FFmpeg 官方仅保证**同 major 内** ABI 向后兼容，跨 major 的 public struct 布局会变化
  （`AVFrame`/`AVCodecContext` 等），已编译二进制依赖的 soname 在系统升级后可能直接消失
  （Arch 只保留最新 major）；
- 已实施的 0d5b65c 内嵌方案：bundle 自带构建机版本 FFmpeg 运行库 + `$ORIGIN` RUNPATH，
  引擎永远自洽，但**不跟随系统**（系统 FFmpeg 更新后引擎仍用旧库，无法获得新编解码能力）。

### 1.2 用户场景差异

| 平台 | 系统 FFmpeg 可用性 | 结论 |
|---|---|---|
| Linux（发行版） | 多数发行版自带 FFmpeg 运行库（Arch/Fedora/Ubuntu 均有） | 可跟随系统自编译 |
| macOS | Homebrew 常有但系统无（Apple 不内置） | 大概率无系统 FFmpeg |
| **Windows** | **用户几乎不可能安装或知道 FFmpeg** | **必须保留内嵌，自编译仅作可选** |

> Windows 定位：内嵌 FFmpeg 运行库（vcpkg `x64-windows-release` 已落地）是唯一可靠路径，
> 自编译框架在 Windows 上不做主力，只保留能力入口（见 §7）。

---

## 2. 方案总览：着色器编译式自编译

对标 GPU 驱动的 pipeline cache：编译产物绑定运行环境（GPU/驱动）→ 首次运行编译并缓存 →
环境变化（驱动更新）指纹失效 → 自动重建。

```
bundle/（新增内嵌，体积可控）
├── engine-src/               引擎源码（已存在，0d5b65c）
├── ffmpeg-headers/6.x        FFmpeg 6 头文件套件（同 major 内 ABI 向后兼容）
├── ffmpeg-headers/7.x        FFmpeg 7 头文件套件
├── ffmpeg-headers/8.x        FFmpeg 8 头文件套件
├── tcc/                      tcc 编译器二进制（自带工具链，用户零安装）
└── native/                   预编译引擎 + 内嵌 FFmpeg 运行库（兜底，已存在）

启动时序：
1. 探测系统 FFmpeg 运行库 soname（ldconfig / 直接 dlopen 探测实际 .so.XX）
2. 计算指纹 = (avformat_major, avcodec_major, avutil_major, swresample_major)
3. 缓存命中 ~/.cache/archoera/engine/<fp>/ → 直接加载（完全跟随系统版本）
4. 未命中且有系统 FFmpeg → 用 tcc + 对应 major 头文件编译引擎（链接系统当前运行库）→ 缓存
5. 无系统 FFmpeg / 编译失败 → 回退 bundle 内嵌预编译库（永远可用）
```

### 2.1 为什么选 tcc（TinyCC）

| 维度 | 评估 |
|---|---|
| 内嵌性 | 支持 libtcc 库模式，或直接打包 tcc 可执行文件（x86-64 约 100KB-2MB） |
| 三平台 | Linux / macOS(x86-64+ARM64) / Windows 全支持；`-shared` 直接产 .so/dylib/dll，自带汇编器+链接器，**不需要外部 binutils** |
| 编译速度 | 比 GCC 快约 9 倍，引擎（~15 个 .c）预计 1-2 秒 |
| 依赖 | 无——自身即完整 C 工具链，用户机器零安装 |
| 维护 | TinyCC/tinycc mob 分支活跃（2026 仍在提交）；LGPL 许可与项目 AGPL 兼容 |
| 已知短板 | 优化弱于 gcc/clang（-O2 支持有限）；**无法编译 Rust**（tempo 模块降级） |

> 不选 Zig cc / 打包 clang：体积（~100MB+）与分发复杂度远超 tcc，且对「编译自己
> 固定的 15 个 C 文件」的场景属于杀鸡用牛刀。

---

## 3. 运行时架构

### 3.1 四层职责

| 层 | 职责 | 位置 |
|---|---|---|
| Fingerprint | 探测系统 FFmpeg 实际 soname + 引擎源码 hash，产出指纹字符串 | Dart 侧（`engine_builder.dart`） |
| Detector | 指纹 ↔ 缓存目录比对，决策「加载缓存 / 触发编译 / 回退内嵌」 | Dart 侧 |
| Builder | 调 tcc 编译引擎源码 → 链接系统 FFmpeg → 产物原子写入缓存 | 原生子进程（`tcc` CLI 或内嵌驱动） |
| Cache | 产物按指纹命名；启动时按指纹选择加载路径 | `~/.cache/archoera/engine/<fp>/` |

### 3.2 指纹算法

```
fp = sha256(
  "avformat:" + avformat_major + "|" +
  "avcodec:"  + avcodec_major  + "|" +
  "avutil:"   + avutil_major   + "|" +
  "swresample:" + swresample_major + "|" +
  engine_src_tree_hash           # 引擎源码目录递归 sha256
)
```

- **只取 major**：同 major 内 soname 不变，引擎无需重建（FFmpeg 同 major ABI 兼容保证）；
- **源码 hash**：引擎源码变化（应用升级）也会触发重建；
- 探测方式：Linux 用 `ldconfig -p` 或逐个 `dlopen("libavformat.so.N")`；macOS 用
  `dlopen("libavformat.N.dylib")`；Windows 不做系统探测（见 §7）。

### 3.3 缓存布局

```
~/.cache/archoera/engine/
├── <fp>/libarchoera_mediaengine.so    # tcc 编译产物
├── <fp>/libfft.so
├── <fp>/archoera-audio-engine
├── <fp>/manifest.json                  # 指纹 + 编译时间 + tcc 版本
└── <fp>/.building                      # 编译中标记（原子性）
```

- 启动时 `manifest.json` 指纹与当前指纹比对，一致 → 直接加载 `<fp>/` 产物；
- 编译进行中（`.building` 存在且未过期）→ 本次会话回退内嵌，不重复编译；
- 用户可清缓存（设置页入口），等价恢复官方内嵌行为。

### 3.4 编译流程（Builder）

```
1. 探测系统 FFmpeg 头文件版本 → 选 bundle 内对应 major 的 ffmpeg-headers 套件
   （无对应 major → 放弃自编译，回退内嵌）
2. tcc -shared -fPIC -O2 -I<ffmpeg-headers>/<major> -L<系统 lib 目录> \
     <engine-src>/*.c -lavformat -lavcodec -lavutil -lswresample -lpthread -ldl \
     -o <fp>/libarchoera_mediaengine.so
3. 链接用「无版本号 -l 名」让 tcc 解析到系统**当前** soname
   → 产物 NEEDED 即系统当前版本，系统升级后指纹失效自动重编
4. 产物先写临时目录，全部成功后再 rename 到 <fp>/（原子替换）
```

### 3.5 回退链（永不裸奔）

```
自编译产物可用 ──► 加载 <fp>/ 产物
   │ 未命中/失败
   ▼
bundle 内嵌 FFmpeg 运行库 + 预编译引擎（0d5b65c，永远可用）
```

---

## 4. 编译降级项

| 功能 | tcc 自编译产物 | 内嵌预编译产物 | 影响 |
|---|---|---|---|
| Rust tempo（变速变调） | **不可用**（tcc 不编译 Rust） | 可用 | 自编译产物 tempo 降级，其余功能不变 |
| EQ / FFT / limiter | 可用（tcc 编译，性能略低于 gcc） | 可用 | 计算热点性能需验证（见 §6 验证项） |
| 解码 / 重采样 | 可用（调用 FFmpeg 函数，性能在 FFmpeg 侧） | 可用 | 无差异 |

> 结论：自编译产物是「功能完整、tempo 降级、性能近似」的可行形态；用户无需感知差异。

---

## 5. 落地步骤（分四步）

### 步骤①：Builder 骨架（Linux 先行）
- 写 `rebuild-engine.sh` 的 tcc 变体 `build-engine-tcc.sh`（§3.4 流程脚本化）；
- bundle 打包脚本（`package.sh` / CI）新增 `ffmpeg-headers/{6,7,8}` 与 `tcc/` 安装目标；
- 本机验证 tcc 编译产物可加载、可播放。

### 步骤②：Dart 运行时接入（指纹 + 缓存 + 回退）
- 新增 `app/lib/services/playback/engine_builder.dart`：
  Fingerprint / Detector / Cache 三层的 Dart 实现；
- `audio_engine_process.dart` 启动路径改为：Detector 决策 → 按结果选加载路径；
- 设置页「高级 · 引擎」区：显示当前引擎来源（内嵌/自编译）、指纹、清缓存、手动重建。

### 步骤③：后台异步编译
- 未命中且有系统 FFmpeg → 后台进程编译（当前会话继续用内嵌库播放，零等待）；
- 编译完成写指纹 → **下次启动生效**；
- 失败打日志 + 回退内嵌，设置页可见失败原因。

### 步骤④：多平台与验证
- Linux 全面验证（Ubuntu/Arch 双 FFmpeg major 切换测试）；
- macOS：Homebrew FFmpeg 存在时可用自编译，否则内嵌；
- Windows：保留能力入口但不做主力（见 §7）；CI 三平台构建回归。

---

## 6. 验证方案

| 项 | 方法 |
|---|---|
| tcc 编译可行性 | 本机用 tcc 编译引擎 → `ldd` 确认 NEEDED 指向系统 soname → 启动播放 |
| 性能 | 自编译 vs 预编译：EQ/FFT 峰值 CPU 对比（`-O2` 是否够用） |
| 指纹正确性 | 系统 FFmpeg 6→7→8 切换后，指纹变化 → 自动重编 → 加载新产物 |
| 回退 | 删除系统 FFmpeg 运行库 → 应用仍用内嵌库播放 |
| 原子性 | 编译中断 → 重启不残留半成品，`.building` 清理 |
| Windows 回归 | 内嵌链路不受影响（vcpkg 运行库 + 预编译引擎） |

---

## 7. 平台策略差异

| 平台 | 系统 FFmpeg 探测 | 自编译 | 兜底 |
|---|---|---|---|
| Linux | `ldconfig -p` / dlopen soname | 主力 | 内嵌运行库 |
| macOS | `dlopen libavformat.N.dylib`（Homebrew） | 可选（有则跟，无则内嵌） | 内嵌运行库 |
| **Windows** | **不探测**（用户几乎不可能有 FFmpeg） | **不做主力**，仅保留 `tcc -shared` 能力入口与设置页手动重建 | **内嵌运行库（唯一路径）** |

> Windows 现状已满足：vcpkg `x64-windows-release` 动态 triplet 编译，运行时 FFmpeg DLL
> 已拷入 exe 根目录（windows/CMakeLists.txt）。自编译框架在 Windows 上仅承诺「不破坏现状」。

---

## 8. 风险与取舍

1. **tcc 优化弱**：EQ/FFT 热点若性能不达标，可对热点文件保留 gcc 预编译（混合产物），
   或接受近似性能（解码在 FFmpeg 侧，引擎非瓶颈）；
2. **头文件版本覆盖**：bundle 只带 6/7/8 三套头文件，系统 FFmpeg 若为 5.x/9.x 极端版本
   → 无对应头文件 → 回退内嵌（安全，不裸奔）；
3. **体积**：三套 FFmpeg 头文件（每套约 0.5-1MB）+ tcc（1-2MB）+ 引擎源码（已有），
   整体增幅约 3-5MB，可接受；
4. **供应链**：tcc 为 LGPL，随应用分发合规（提供 relink 能力已由 0d5b65c engine-src 承担）；
5. **不做「强制兼容低版本」**：明确不实现 dlopen + struct accessor 封装层（ffmpeg-loader 路线）
   ——跨 major ABI 不稳定，维护成本高，重编译是更结构化的解。

---

## 9. 参考

- [TinyCC 官方](https://www.bellard.org/tcc/)：~100KB-2MB、比 GCC 快 9 倍、libtcc 可内嵌
- [TinyCC 文档](https://github.com/TinyCC/tinycc/blob/mob/tcc-doc.texi)：三平台目标表、`-shared` 支持
- [mdk-sdk FFmpeg Runtime](https://github.com/wang-bin/mdk-sdk/wiki/FFmpeg-Runtime)：运行时按
  bundle > 系统版本匹配加载（本方案的「跟随系统」参照）
- [Qt Multimedia FFmpeg stubs](https://doc.qt.io/qt-6.10/qtmultimedia-ffmpeg-stubs.html)：stub 库 +
  dlopen 优雅降级（回退思路参照）
- [FFmpeg 官方 ABI 说明](https://www.ffmpeg.org/doxygen/trunk/)：仅同 major 内保证向后兼容
- HN 讨论：运行时依赖解析需谨慎，必须保留 bundle 兜底
