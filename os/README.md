# ArchoeraOS（`os/`）

> [!CAUTION]
> **Caution**：本分支纯属娱乐项目，只是用于抨击部分过度代码洁癖等的项目。
> 即使可以正常使用，也非常不建议作为主力机（你还要当主力机？！）食用。

把 ArchoeraMusic 从「一个应用」变成「整个系统界面」的实验层：一个自研的 Wayland
kiosk 合成器，让播放器以唯一一个全屏客户端构成系统 shell。

> 状态：**可运行的嵌套原型 + 可编译的裸机后端**。合成器（`archoera-shell`）、自定义协议、
> 控制面客户端（`archoera-control`）与冒烟客户端（`archoera-smoke`）均已在 WSLg 的
> Wayland 会话中端到端验证通过；`zwp_linux_dmabuf_v1` 已注册（Flutter/GTK 的 EGL 前提）。
> 裸机（DRM/KMS + libinput + libseat）后端已实现并**编译验证**，但因开发机无 `/dev/dri`，
> **尚未在真实硬件上运行验证**。
>
> 本目录独立于 `app/`（Flutter 应用）与 `app/native/platform`（C++ 平台桥接）：
> 它承载「把播放器变成系统」所需的用户会话层。设计文档见
> [`docs/archoera-os.md`](../docs/archoera-os.md)。

## 目录结构

```
os/
├── Cargo.toml                     # workspace
├── protocol/
│   └── archoera-shell-v1.xml      # 自定义协议（服务端/客户端共享同一份定义）
├── archoera-shell/                # kiosk Wayland 合成器（smithay）
│   └── src/
│       ├── main.rs                # 入口 / 会话看门狗
│       ├── cli.rs                 # 启动参数
│       ├── state.rs               # 全局状态 + Wayland listener
│       ├── kiosk.rs               # 全屏 / 无装饰 / 单窗口策略
│       ├── input.rs               # 媒体键映射
│       ├── protocol/              # 自定义协议服务端绑定（proc-macro）
│       ├── handlers/              # compositor / xdg-shell / dmabuf / archoera_shell_v1
│       ├── control/               # logind / 背光 / 电池 控制面
│       └── backend/               # winit（嵌套，默认）/ udev（DRM/KMS）
├── archoera-control/              # 控制面 CLI + 协议客户端
└── archoera-smoke/                # 最小 xdg-toplevel + wl_shm 冒烟客户端
```

## 构建

```bash
cd os
cargo build --workspace          # 或 cargo build --release
cargo check --workspace          # 0 warning
cargo fmt --all -- --check
```

依赖：

- **通用**：Rust 1.80+（实测 1.98）；嵌套后端需要系统提供 EGL/GLES。
- **`udev` 裸机后端**（可选）：`libdrm` / `gbm` / `libinput` / `libudev` / `libseat`
  的开发文件（pkg-config 可见）。在 **Arch Linux** 上，`libseat` 没有独立包——它由
  `extra/seatd` 提供（`Provides: libseat.so`，含 `libseat.h` / `libseat.so` /
  `libseat.pc`）：

  ```bash
  sudo pacman -S seatd          # 关键依赖：libseat 的 header + .so + pkg-config
  # 其余在 Arch 上由 libdrm / mesa / libinput / systemd 提供，装好后 pkg-config 均可见
  cargo build -p archoera-shell --features udev
  ```

> ⚠️ **WSL2 无法运行 `udev` 后端**：WSL2 只有 `/dev/dxg`，**没有 `/dev/dri` 与
> `/dev/input`**，Mesa 也以软件后端（llvmpipe）运行。使用 WSL 时只做**编译验证**，
> 真正跑 DRM/KMS 需要在真实 Arch 硬件或带 virtio-gpu 的虚拟机上。

## 运行（嵌套，开发/测试）

在已有的 Wayland（或 WSLg）会话里，把合成器跑成一个普通窗口：

```bash
# 默认后端 = winit；会自动挑一个 WAYLAND_DISPLAY 名并打印出来
./target/debug/archoera-shell --socket archoera-test
```

然后另开终端，把客户端接到它上面：

```bash
# 覆盖 WAYLAND_DISPLAY，或直接用 --socket
./target/debug/archoera-control --socket archoera-test status
./target/debug/archoera-smoke   --socket archoera-test
```

若要托管真正的播放器：

```bash
./target/debug/archoera-shell --socket archoera-test -- /path/to/archoera_music
# 或：--command "archoera_music --flag"，或设置 ARCHOERA_SESSION_APP
```

合成器会把 `WAYLAND_DISPLAY=archoera-test` 注入被托管的会话命令，客户端退出后
（`--no-exit-on-close` 未指定时）整个 kiosk 会话结束。

## 运行（裸机 DRM/KMS）

在**没有桌面会话**的机器上，用 `udev` 后端直接接管显卡与输入（普通用户即可，
设备经 libseat 打开）：

```bash
# 需要 seatd 包提供的 libseat 开发文件（Arch：extra/seatd），见上文构建说明
cargo build -p archoera-shell --features udev
# seatd 常驻服务可选：libseat 未找到 /run/seatd.sock 时会自动回退到 logind（内置后端）。
# 普通用户即可；无需 root / polkit。可用 LIBSEAT_BACKEND=logind|seatd 强制指定。
sudo systemctl enable --now seatd        # 可选
./target/debug/archoera-shell --backend udev -- /path/to/archoera_music
```

实现要点：单 GPU（首个可用 DRM 设备，或 `--drm-device` 显式指定）→ GBM 分配 + EGL/GLES
渲染 → 每个连接器一个 `DrmOutput`，vblank 到达后回收上一帧；**仅在有新客户端提交时**再
合成并 `queue_frame`，空帧不再排队，vblank 随之停止（客户端提交经 `schedule_redraw` 唤醒），
故空闲时零功耗。输入经 libinput 注入同一 seat；会话被抢占（VT 切换）时暂停渲染与输入，
恢复后重新激活输出。dmabuf 以 **v4 反馈**注册，告知客户端主渲染设备。

连接器**热插拔**会增量重扫：新接入的连接器被点亮并挂到 `space`（kiosk 窗口仍在主输出上，
不做跨屏迁移），断开的输出被移除；主输出消失时自动改选剩余输出，一块都不剩则广播
`shutting_down` 并结束会话。主 DRM 设备被移除时同样结束会话。

> ⚠️ 该后端**尚未在真实硬件上验证**，首次上机请重点检查连接器枚举、模式选择与
> vblank 回收。

### 启动参数

| 参数 | 说明 |
|---|---|
| `--socket <name>` | 固定 `WAYLAND_DISPLAY` 名（默认自动分配） |
| `-c, --command <line>` | 按空白拆分的会话命令 |
| `-- <argv...>` | 余下参数整体作为会话命令（可含带空格参数） |
| `--backend <winit\|udev>` | 运行后端（默认 `winit`） |
| `--volume <0-100>` | 初始会话音量 |
| `--no-exit-on-close` | 客户端全退后不结束会话 |
| `--allow-multiple` | 允许第二个 toplevel（默认 kiosk 只接受一个） |
| `--drm-device <path>` | udev 后端指定 DRM 节点（默认固件主 GPU，可用 `ARCHOERA_DRM_DEVICE` 兜底） |

## 控制面 CLI（`archoera-control`）

协议客户端 / 命令行工具，同时也是 `archoera_shell_v1` 的端到端验证器：

```bash
archoera-control [--socket <name>] [命令]
```

| 命令 | 说明 |
|---|---|
| `status`（默认） | 打印能力位与当前系统状态 |
| `watch` | 持续监听并打印会话事件（媒体键 / 亮度 / 电量） |
| `brightness <0-100>` | 设置背光亮度 |
| `volume <0-100>` | 设置会话音量 |
| `power-off` | 关闭系统电源 |
| `reboot` | 重启系统 |

## `archoera_shell_v1` 协议速览

全局对象，每个客户端绑定一次；合成器在 bind 时立即下发 `capabilities` 与当前状态。

| 方向 | 名称 | 说明 |
|---|---|---|
| request | `destroy` | 销毁本地 shell 对象 |
| request | `power_off` / `reboot` | 系统电源动作 |
| request | `set_brightness(percent)` | 设置背光（0-100） |
| request | `set_volume(percent)` | 设置会话音量（由播放器落实） |
| event | `capabilities(flags)` | 能力位：`brightness=1` `power=2` `volume=4` `media_keys=8` `battery=16` |
| event | `brightness_changed` / `volume_changed` | 当前值（0-100） |
| event | `media_key(key)` | `play_pause/next/previous/stop/volume_up/volume_down/mute` |
| event | `battery(present, percent, charging)` | 电池状态 |
| event | `session(state)` | `ready` / `shutting_down` |

未置位的能力对应请求会被**静默忽略**（不产生协议错误），客户端不应据此崩溃。

## 平台与权限

- **普通用户即可**：电源/亮度经 systemd-logind（D-Bus，`zbus`）完成，不请求 root、
  不写特权路径、不装服务/驱动；`logind` 不可用时（容器 / WSL）控制面自动降级为只读，
  背光另有 `/sys/class/backlight` 直读兜底。
- **不依赖 X11**：合成器与所有客户端走纯 Wayland。嵌套开发时 winit 可能落到 X11
  后端（README 的验证用的是 WSLg 的 Wayland 会话）。
- **udev / 裸机后端**：`--backend udev` 需以 `--features udev` 构建；未启用该 feature 时
  会明确报错，而不是静默回退到 winit。设备经 libseat 打开，全程普通用户权限。

## 已知缺口

- **`zwp_linux_dmabuf_v1` 已提供**：winit 后端注册 **v3** 全局，udev 后端注册 **v4**
  反馈；两者共用共享状态里的 `GlesRenderer`，`dmabuf_imported` 同步导入缓冲。
  渲染器不报告任何 dmabuf 格式时（纯软件渲染）会跳过注册，客户端自动回退 `wl_shm`。
  注：真实 GPU 上嵌套实测上报 236 个格式；WSLg/WSL2 下 dmabuf 分配仍受限。
- **Flutter 端到端未验证**：需要能分配 dmabuf 的真实 GPU；`archoera-smoke`（`wl_shm`）
  仅验证合成器客户端面渲染通路。
- **udev 后端未上机验证**：为避免抢占当前桌面会话（KDE Wayland 持有 DRM master /
  输入），开发期仍只做**编译验证**；真实上机请重点检查连接器枚举、模式选择、vblank 回收
  与热插拔。多 GPU **合成**（`MultiRenderer`）、DRM lease、同步对象（syncobj）未实现；
  单卡 + `--drm-device` 选择与连接器热插拔已实现。

## 许可

AGPL-3.0-or-later，与仓库其余部分一致。
