# ArchoeraOS：把播放器变成系统（ArchoeraOS Design）

> 状态：**进行中（2026-09-17）**——嵌套原型端到端跑通（合成器 + 自定义协议 + 控制面 +
> 冒烟客户端）；DRM/KMS 裸机后端与 `linux-dmabuf` 未实现。
> 目标：在 x86_64 通用 PC / 虚拟机上，让 ArchoeraMusic **以全屏唯一客户端的形态成为
> 整个系统界面**（kiosk 会话），而不是运行在某个桌面里的一个窗口。
> 范围：用户会话层——Wayland 合成器、会话级控制协议、kiosk 策略；不含内核/驱动。
> 关联：[`../os/README.md`](../os/README.md)、
> [player-render-optimization.md](player-render-optimization.md)、
> [platform-native-bridge.md](platform-native-bridge.md)、
> [architecture.md](architecture.md)。

---

## 0. TL;DR

- **形态**：先做**可直接运行的合成器**（嵌套开发），再做**裸机 DRM/KMS 会话**；
  不做完整可引导镜像（那属于后续打包层）。
- **地基**：**自研纯 Rust 合成器**（[smithay](https://github.com/Smithay/smithay) 0.7），
  不套 wlroots / cage。理由：kiosk 语义极窄（一个窗口、铺满、无装饰），但需要深度
  定制（媒体键、电源、防休眠、亮度的会话级控制），自研比配置现成合成器更直接。
- **Rust 的职责**：合成器 + 自定义 `archoera_shell_v1` 协议 + 控制面（关机/重启/亮度/音量/媒体键）。
- **权限纪律**：控制面一律**普通用户**完成——systemd-logind over D-Bus；不 root、
  不提权、不写特权路径、不装服务/驱动。
- **dmabuf 已提供**：renderer 上提到共享状态后，winit 注册 `zwp_linux_dmabuf_v1` v3、
  udev 注册 v4 feedback；Flutter（GTK3 + EGL）在纯 Wayland 下的 EGL 前提已具备（见 §10）。
- **验证**：WSLg 的 Wayland 会话下，合成器稳定运行；`archoera-smoke` 被配置为
  1280×800 `MAXIMIZED|ACTIVATED` 并持续出帧；`archoera-control` 完成状态读取与
  音量往返（42% 服务端持久）；dmabuf 全局注册（114 格式）。裸机后端已编译验证，
  未上机。

---

## 1. 目标与非目标

**目标**

1. 播放器启动后**铺满整块屏幕**，无标题栏、无任务栏、无窗口管理器，构成唯一界面。
2. 系统级动作（关机 / 重启 / 亮度 / 防休眠）由**播放器发起**，合成器落实。
3. 硬件媒体键 → 合成器 → 播放器（`media_key` 事件）。
4. 会话状态可选上传（`session`），供播放器在关机前保存 / 淡出。
5. 全程普通用户权限，符合 `AGENTS.md` 的最小权限红线。

**非目标（本阶段）**

- 可引导镜像 / 安装器 / OEM 预装（后续打包层）。
- 多窗口、多任务、多显示器混合 DPI 的桌面级行为。
- 登录管理器 / 用户切换（kiosk 单用户，后续可加）。
- 音频后端本身（音量只是状态镜像，实际音频仍由播放器与其原生层负责）。

---

## 2. 架构总览

```
                    ┌─────────────────────────────── ArchoeraOS 会话 ───────────────────────────────┐
                    │                                                                              │
  systemd-logind ── │  archoera-shell（合成器，smithay）                                            │
   (D-Bus)          │   ├─ Wayland 服务端：wl_compositor / subcompositor / shm / dmabuf / seat / output│
        ▲           │   │                    xdg-shell / xdg-decoration / idle-inhibit / data-device│
        │ zbus      │   ├─ kiosk 策略：单窗口、铺满输出、无装饰、强制 Activated                      │
        │           │   ├─ 渲染：GlesRenderer + Space + OutputDamageTracker（winit 嵌套 / udev 裸机） │
        │           │   ├─ 输入：winit 或 libinput → Seat（媒体键映射）                              │
        │           │   └─ archoera_shell_v1（自定义全局对象）                                       │
        │           └────────────── Wayland（unix socket：WAYLAND_DISPLAY） ───────────────────────┐  │
        │                                                                                          │  │
        │           ┌─ 客户端 ─────────────────────────────────────────────────────────────────┐  │  │
        └───────────┤ ArchoeraMusic（Flutter / GTK3+EGL，目标形态）                              │◄─┘  │
                    │ archoera-control（协议 CLI / 验证器）                                      │     │
                    │ archoera-smoke（xdg-toplevel + wl_shm 冒烟）                               │     │
                    └───────────────────────────────────────────────────────────────────────────┘     │
                    └───────────────────────────────────────────────────────────────────────────────┘
```

- **合成器与客户端同进程模型无关**：客户端是独立进程，通过 Wayland socket 连接；合成器把
  socket 名注入被托管的会话命令。
- **控制面在合成器内**，客户端不直接接触 logind/D-Bus。

---

## 3. 关键决策与理由

| 决策 | 选择 | 理由 |
|---|---|---|
| 合成器基座 | **smithay 0.7（自研）** | 纯 Rust、无 C 依赖；kiosk 语义窄但控制面深，自研比配置 wlroots/cage 更直接 |
| 客户端协议 | **自定义 `archoera_shell_v1`** | 系统级语义（电源/亮度/媒体键/会话）不属于任何既有协议；自定义可精确表达 |
| 协议代码生成 | **`wayland-scanner` proc-macro** | 单一 XML 位于 `os/protocol/`，服务端与客户端各自展开，类型层面保证一致；无需 build.rs |
| 控制面 | **systemd-logind over D-Bus（`zbus`）** | 普通用户即可完成电源/亮度/防休眠；不 root、不提权、无需 polkit 交互 |
| 降级 | 无 logind → 只读能力位；背光另有 sysfs 兜底 | 容器 / WSL / 非 systemd 环境仍能启动与调试 |
| 嵌套后端 | **winit** | 开发期直接在现有 Wayland/WSLg 会话里开窗，迭代快 |
| 裸机后端 | **DRM/KMS + libinput + libseat** | 开机即见、无桌面依赖；libseat 以普通用户取得 DRM/输入，不需 root |
| 权限模型 | **普通用户**，唯一例外是 Windows 安装向导（与本层无关） | `AGENTS.md` 红线；运行时绝不请求提权 |

---

## 4. 组成模块

| 组件 | 路径 | 职责 |
|---|---|---|
| `archoera-shell` | `os/archoera-shell` | kiosk Wayland 合成器：Wayland 前端、kiosk 策略、渲染、输入、控制面、自定义协议服务端 |
| `archoera-control` | `os/archoera-control` | 协议客户端 / CLI：读取能力与状态、下发亮度/音量/电源；端到端验证器 |
| `archoera-smoke` | `os/archoera-smoke` | 最小 xdg-toplevel + `wl_shm` 动画客户端，验证合成器渲染通路 |
| 协议 | `os/protocol/archoera-shell-v1.xml` | 服务端/客户端共享的 `archoera_shell_v1` 定义 |

合成器内部按单一职责拆分（与 `AGENTS.md` 的模块化约定一致）：

```
archoera-shell/src/
├── main.rs          入口、tracing、会话看门狗
├── cli.rs           启动参数（socket / 会话命令 / 后端 / 音量 / 退出策略）
├── state.rs         ArchoeraShell 中心状态、listener、广播 helper、ClientState
├── kiosk.rs         全屏 / 无装饰 / 单窗口策略
├── input.rs         媒体键映射（evdev → XKB keycode = evdev+8）
├── protocol/        自定义协议服务端绑定（proc-macro 展开）
├── handlers/        compositor+shm / dmabuf / xdg_shell(+decoration) / seat+data_device+output+idle_inhibit / archoera_shell_v1
├── control/         logind.rs + brightness.rs + battery.rs（策略/机制分层）
└── backend/         mod.rs（Backend 抽象）+ winit.rs（默认）/ udev.rs（DRM/KMS，需 libseat）
```

---

## 5. 会话与 kiosk 策略

- **一个会话、一块输出、一个客户端**。所有 xdg-toplevel 一律被配置为
  `输出尺寸 + Maximized + Activated`；客户端请求 fullscreen 时升级为 `Fullscreen`。
- **装饰固定 `ServerSide`**（合成器不绘制任何装饰）→ 客户端放弃 CSD、铺满全屏。
  这是「无标题栏」的关键：不是隐藏装饰，而是让客户端根本不画。
- **忽略移动 / 缩放 / 最大化取消请求**，kiosk 永远占据整屏。
- **看门狗**：客户端曾接入且全部退出后结束会话（`--no-exit-on-close` 可关闭）。
- **输出变化**：winit 窗口 resize 时把 `Size<Physical>` 转 `Logical` 后重配所有窗口。

> 说明：`kiosk.rs` 集中了「是否接受窗口」的策略点（`accepts`），后续可在此加白名单 /
> 拒绝第二个客户端等约束。

---

## 6. 控制面（普通用户、可降级）

- `Logind::connect()` 连系统总线；失败则 `logind = None`。
- **电源**：`PowerOff` / `Reboot`（先 `interactive=false`，失败再 `true`）。
- **亮度**：优先 `/sys/class/backlight` 直写（`brightness.rs`），logind
  `Session.SetBrightness` 兜底；两者都没有 → 不置 `brightness` 能力位。
- **防休眠**：`zwp_idle_inhibit_manager_v1` → `logind.Inhibit("idle", ..., "block")`，
  持有 fd 即生效，丢弃即释放；抑制计数归零才释放。
- **电池**：`/sys/class/power_supply` 采样，周期性广播。
- **音量**：合成器只做**状态镜像**与事件广播，实际音频由播放器落实（`set_volume`
  仅更新内部值并回 `volume_changed`）。
- **媒体键**：合成器把硬件键映射为 `media_key` 事件下发给播放器。
- **能力位**：按实际可用性动态计算（背光/logind/电池各自决定是否置位），bind 时下发。

---

## 7. `archoera_shell_v1` 协议

全局对象，每客户端绑定一次；bind 时立即下发 `capabilities` + 当前状态（亮度/音量/电池/会话）。

| 方向 | 名称 | 参数 |
|---|---|---|
| request | `destroy` | （destructor） |
| request | `power_off` / `reboot` | — |
| request | `set_brightness` | `percent: uint` |
| request | `set_volume` | `percent: uint` |
| event | `capabilities` | `flags: uint`（bitfield） |
| event | `brightness_changed` / `volume_changed` | `percent: uint` |
| event | `media_key` | `key: enum media_key` |
| event | `battery` | `present/percent/charging: uint` |
| event | `session` | `state: enum session_state` |

能力位：`brightness=1`、`power=2`、`volume=4`、`media_keys=8`、`battery=16`。
**未置位的请求被静默忽略**（不报协议错误），保证前后兼容与降级安全。

设计要点：越界百分比由合成器夹取；`destroy` 只销毁协议对象，不影响会话本身；
`session = shutting_down` 在电源动作**之前**广播并 flush，给播放器保存/淡出的机会。

---

## 8. 渲染路径

- `GlesRenderer` + `smithay::desktop::space::render_output` + `OutputDamageTracker`；
  kiosk 底色 `#0E1117`（对齐 `AppPalette.dark.surface`）。
- 每帧 `submit` 后对所有窗口 `send_frame`（驱动客户端 `wl_surface.frame` 回调），
  `space.refresh()` / `popups.cleanup()` / `flush_clients()`。
- **事件驱动的按需重绘**（取代原型期的「永远重绘」）：`ArchoeraShell` 持有
  `needs_redraw` 标志，客户端消息（缓冲提交 / 帧回调请求 / 协议请求）与输出变化
  置位，随后 `schedule_redraw()` 唤醒后端——winit 请求一次窗口重绘、udev 同步合成
  一帧。无客户端活动时合成器完全空闲（实测嵌套空闲 CPU ≈ 0，主线程阻塞在
  `epoll_wait`），有活动时按客户端节奏出帧。
- **渲染后端拥有自己的输出状态**（`backend/mod.rs`）：`WinitBackend` 持有
  `WinitGraphicsBackend` + `Output` + `OutputDamageTracker`；`UdevBackend` 持有
  `GlesRenderer` + `DrmOutputManager` + 每 CRTC 的 `DrmOutput`。对外只暴露
  `render(space)`，`ArchoeraShell::render_frame` 负责帧回调与清理。
- **dmabuf**：renderer 由后端持有并可被 `DmabufHandler` 同步借用——winit 注册 v3、
  udev 注册 v4（`DmabufFeedbackBuilder`）。
- 播放器自身的重渲染优化（着色器、损伤区、字形图集）见
  [`player-render-optimization.md`](player-render-optimization.md)，与本层正交。

---

## 9. 构建、运行与本次验证

```bash
cd os
cargo fmt --all -- --check          # 通过
cargo check --workspace             # 0 warning（默认 winit 后端）
cargo build --workspace
# 裸机后端（需 libseat，见 §13）
cargo check -p archoera-shell --features udev
```

> 若只想做**类型检查**而无 `libseat`：`libseat-sys` 的 `build.rs` 会走 `pkg-config`，
> 而 `cargo check` 不链接。放一个最小 `libseat.pc` 并设 `PKG_CONFIG_PATH` 即可通过；
> 真正构建/运行仍必须安装 `extra/seatd`。

本次在 **WSL2 + WSLg（Wayland `wayland-0`，1280×800）** 的验证：

1. `archoera-shell --socket archoera-wl` 作为嵌套窗口稳定运行（默认 winit 后端）。
2. `archoera-control --socket archoera-wl status`：

   ```
   能力: power, volume, media_keys, battery
   亮度: 不可用
   音量: 100%
   电池: 84%（充电中）
   会话: 就绪
   ```

3. `archoera-control ... volume 42` → 新客户端再读为 42%（服务端状态持久）。
4. `archoera-smoke --socket archoera-wl`：

   ```
   configure: 1280x800 WindowConfigure { new_size: (Some(1280), Some(800)),
     state: WindowState(MAXIMIZED | ACTIVATED), decoration_mode: Server, ... }
   ```

   并持续出帧至超时（xdg-shell 配置 + kiosk 全屏 + shm 缓冲 + 帧回调全通）。
5. dmabuf 注册：启动日志出现 `已注册 zwp_linux_dmabuf_v1 formats=114 dmabuf_v4=false`
   （WSLg 的 d3d12 Mesa 上报 114 个格式；纯软件渲染时会跳过并回退 `wl_shm`）。

> 环境注记（本机为 **Arch Linux + WSL2**）：
> - WSLg 下 MESA 会打印 `ZINK ... VK_ERROR_INCOMPATIBLE_DRIVER` / `failed to create
>   dri2 screen`，属宿主 GPU 探测噪声，合成器仍以软件路径正常渲染。
> - 嵌套窗口若在 WSLg 的 **Wayland** 后端被宿主关闭，可回退 `WINIT_UNIX_BACKEND=x11`；
>   但合成器本身与客户端始终走纯 Wayland，不依赖 X11。
> - **`udev` 后端在本机只能编译、不能运行**：WSL2 只有 `/dev/dxg`，无 `/dev/dri` 与
>   `/dev/input`。编译前需 `sudo pacman -S seatd`（Arch 上 `libseat` 由 `extra/seatd`
>   提供，含 header / `.so` / `pkg-config`）；`libdrm` / `gbm` / `libinput` / `libudev`
>   已由系统包提供且 `pkg-config` 可见。实际运行请用真实 Arch 硬件或 virtio-gpu 虚拟机。

---

## 10. 与 Flutter（ArchoeraMusic）的衔接

目标形态下，ArchoeraMusic 是一个 **GTK3 + EGL** 的 Wayland 客户端。GTK3 的 Wayland GL
路径依赖 **`zwp_linux_dmabuf_v1`**（或旧的 `wl_drm`）来分配/呈现 EGL 缓冲；缺失时
GTK 只能退化到软件绘制，而 Flutter Linux embedder 要求 GL，因此**必须提供 dmabuf**。

**已解决**：渲染后端的 refactor 让 `GlesRenderer` 从事件回调里上提到共享状态，
`DmabufHandler` 因此可以**同步**导入客户端缓冲：

1. `Backend`（`WinitBackend` / `UdevBackend`）持有 renderer，暴露 `renderer() -> &mut GlesRenderer`；
2. 后端初始化后调用 `ArchoeraShell::setup_dmabuf(renderer, device_id)`：
   - winit（无 render node）→ `create_global`（**v3**）；
   - udev → `DmabufFeedbackBuilder` + `create_global_with_default_feedback`（**v4**）；
3. `impl DmabufHandler`（`handlers/dmabuf.rs`）：`dmabuf_imported` 内
   `renderer.import_dmabuf(&dmabuf, None)` 成功则 `notifier.successful::<State>()`，
   失败则 `notifier.failed()`；
4. 渲染器不报告任何格式时**跳过注册**，客户端自动回退 `wl_shm`（WSLg 实测上报 114 个）。

**仍未验证**：Flutter 的端到端 GL 渲染需要真实 GPU 上能分配/导入 dmabuf 的环境；
`archoera-smoke` 只覆盖 `wl_shm` 路径。这是下一步（P3）的首要目标。

---

## 11. 路线图

| 阶段 | 内容 | 状态 |
|---|---|---|
| P0 | 嵌套合成器 + kiosk 策略 + 自定义协议 + 控制面 + 冒烟客户端 | ✅ |
| P1 | `linux-dmabuf`（winit v3 / udev v4 feedback），renderer 上提共享状态 | ✅ |
| P2 | udev 后端（DRM/KMS + libinput + libseat），编译验证 | ✅（未上机） |
| P3 | 会话接入：`ARCHOERA_SESSION_APP` 拉起 Flutter 播放器并验证全屏渲染 | ⬜ 下一步 |
| P4 | 媒体键 / 电源键 / 音量键的端到端（libinput → 播放器） | ⬜ |
| P5 | 开机即视：systemd 用户会话 / getty 自动登录 + 最小 rootfs 打包（独立层） | ⬜ |
| P6 | 运行时不变量校验 / 签名水印 / 安全启动（复用现有发布与验签工具链） | ⬜ |

新增约束（P2 之后）：合成器启动后由后端决定是否 vsync（udev 用 vblank，winit 用
`request_redraw`）；多 GPU / 热插拔 / DRM lease / syncobj 均未实现，kiosk 场景按单卡设计。

---

## 12. 约束与红线

- **最小权限**：合成器与客户端运行时一律普通用户；不请求提权、不写 `HKLM`/系统目录、
  不装服务/驱动。需要提权的能力一律降级或放弃。
- **零子进程 / 零 JSON（沿用仓库约定）**：平台能力通过既有 C++ 桥接或本层原生实现，
  不在 Dart 侧起系统命令；本层 Rust 侧的系统调用集中在 `control/`。
- **纯 Wayland**：客户端协议与渲染不依赖 X11。
- **模块化**：按职责拆文件，新增平台只加一个后端文件（`backend_{platform}` 思路的可移植性）。
- **发布**：本层尚未进入发布流程；发版须遵循 `AGENTS.md`（`CHANGELOG.md` 为 Release 正文唯一来源）。

---

## 13. 依赖清单（Arch Linux）

| 用途 | Arch 包 | 本项目状态 |
|---|---|---|
| Rust 工具链 | `rust` / `rustup` | ✅ 1.98 |
| 嵌套后端（EGL/GLES） | `mesa` | ✅ |
| DRM/KMS | `libdrm` | ✅（`pkg-config` 可见） |
| GBM 分配 | `mesa`（`gbm`） | ✅ |
| 输入 | `libinput` | ✅ |
| 设备枚举 | `systemd`（`libudev`） | ✅ |
| **会话（libseat）** | **`extra/seatd`** | ⚠️ 本机未装（udev 后端硬依赖） |
| 编译工具 | `gcc` / `pkg-config` | ✅ |

要点：

- **Arch 上没有名为 `libseat` 的包**：`libseat` 由 `extra/seatd` 提供
  （`Provides: libseat.so=1-64`，取代旧 `libseat` 包），该包**同时包含开发文件**
  （`/usr/include/libseat.h`、`/usr/lib/libseat.so`、`/usr/lib/pkgconfig/libseat.pc`），
  因此 `sudo pacman -S seatd` 即可满足 smithay 的 `libseat-sys`（其 `build.rs` 走
  `pkg-config::probe_library("libseat")`）。
- **smithay 0.7 只有 libseat 一种会话后端**（`src/backend/session/` 仅 `libseat.rs`），
  没有 logind/direct 备选，所以 `seatd` 是裸机后端的硬依赖。
- **连接器扫描**用官方 `smithay-drm-extras`（`drm_scanner`，仅依赖 `drm`）。其
  `display-info` 默认 feature 已关闭，避免引入 `libdisplay-info` 这一额外系统库。
- **WSL2 只适合编译，不适合运行**：无 `/dev/dri` / `/dev/input`，Mesa 走软件路径；
  `--backend udev` 请到真实 Arch 硬件或 virtio-gpu 虚拟机上验证。
