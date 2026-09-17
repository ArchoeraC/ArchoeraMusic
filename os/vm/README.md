# ArchoeraOS 最小 VM（`os/vm/`）

用 **mkosi** 构建一个最小 Arch 镜像，并在 **QEMU/KVM** 里跑起来，用来验证
`archoera-shell --backend udev`（DRM/KMS + libinput + libseat）——**不碰宿主桌面**。

## 依赖（宿主）

```bash
sudo pacman -S --needed qemu-system-x86 qemu-img edk2-ovmf mkosi python-pefile
```

## 用法

```bash
# 构建镜像（先编 release 二进制放进镜像，再 mkosi --force build）
os/vm/build.sh build

# 构建并启动 VM（自动补 virtio-gpu / 键盘 / 触摸板）
os/vm/build.sh vm
```

镜像为 `Format=disk`（`mkosi.output/archoera-kiosk.raw`，2G 稀疏）。`udev` 后端需要
真实 DRM 设备，因此 `vm` 会透传 `-device virtio-gpu-pci`（mkosi 仅在 `Console=gui`
时自带 GPU）。RAM 默认 2G（≤ 4G）。

## 镜像内容 / 自动启动

- 标准内核 `linux` + systemd + `mesa`/`libdrm`/`libinput`/`libxkbcommon`/`seatd`/`dbus`
  （覆盖 `archoera-shell` udev 二进制的动态依赖）。
- `mkosi.extra/opt/archoera/`：`archoera-shell`（`--features udev`）、`archoera-control`、
  `archoera-smoke`。
- 自动登录用 mkosi 官方 `Autologin=yes`：**root 在 `/dev/tty1`（VT 会话）与 `/dev/hvc0`
  自动登录**。`/etc/profile.d/zz-archoera.sh` 在 tty1 上 `exec` 会话脚本；
  `/usr/local/bin/archoera-session` 循环启动合成器并把日志写入串口 `hvc0`。
  - 之所以必须是 **tty1（VT）**：systemd-logind 只对 VT 会话允许 `TakeControl`，
    串口会话会让 `libseat` 报 `Function not implemented`。
- `Ssh=yes`（VSock）：配合 `mkosi genkey` 可用 `mkosi ssh`（本环境实测未转发 stdout，
  仅作备用）。

## 已验证（virtio-gpu / KVM）

```
use main GPU: /dev/dri/card0 (Primary)
已点亮输出 connector=Virtual-1 mode=1280x800@75
DRM 输出已就绪 outputs=1
已注册 zwp_linux_dmabuf_v1 formats=114 dmabuf_v4=true
已拉起会话客户端 /opt/archoera/archoera-smoke
ArchoeraOS 冒烟客户端已连接（Ctrl-C 退出）
configure: 1280x800 ... MAXIMIZED | ACTIVATED   ← 客户端拿到 kiosk 全屏配置
```

即：libseat(会话) → DRM 主设备 → 模式选择 → 输出点亮 → GBM/EGL 渲染器 →
dmabuf v4 反馈 → 客户端接入 → configure → 出帧，全链路在真实 DRM/KMS 上跑通。

### 该 VM 暴露并修复的两个真实缺陷

1. **udev 未设置主输出**：`init_udev` 只把 `Output` 放进 `space`，没设
   `ArchoeraShell.output`，导致 `output_rect()` 恒为 `None`，kiosk 永不发 configure
   （客户端不绘制，只剩深色底 → 看起来像黑屏）。
2. **从不 flush 客户端事件**：winit 是在 `Redraw` 里 `flush_clients` 的，udev 路径没有；
   事件驱动之后 registry 全局 / configure / 帧回调都闷在缓冲里，客户端卡死
   （`registry_queue_init` 永不返回）。现于「客户端派发后」与「每帧渲染后」各冲刷一次。

## 说明 / 限制

- **VM 内以 root 自动登录**（mkosi `Autologin=` 仅支持 root）：用于验证 DRM/KMS 通路。
  生产形态是**普通用户**的 kiosk 会话（`sysusers.d/kiosk.conf` 已备好）。
- 首次启动 initrd 里可能有较长的 D-Bus 停止等待，引导偏慢；用**事件等待**
  （轮询串口日志出现关键标记）比固定 sleep 更省时。
- 目录镜像（`Format=directory`）需要 `ForeignUIDRange=yes` + 宿主
  `systemd-nsresourced`；本配置改用磁盘镜像规避。
- 迭代提速：日常只需 `mkosi --force build`（包已缓存）；只改 `mkosi.extra/` 时同样
  需要重建，但无需重新下载软件包。
