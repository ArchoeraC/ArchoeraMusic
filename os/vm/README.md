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
- `mkosi.extra/opt/archoera-music/`：**真实播放器 bundle**（`build.sh` 从
  `app/build/linux/x64/release/bundle` 复制；已 gitignore）。运行库对齐
  `packaging/linux/PKGBUILD` 的 `depends`，另加 `ffmpeg`/`glycin`/`icu`
  （bundle 内嵌 FFmpeg 动态依赖系统编解码库）与 `libsecret`/`adwaita-icon-theme`。
- `mkosi.extra/etc/locale.conf` + `mkosi.postinst`：生成 `en_US.UTF-8`/`zh_CN.UTF-8`。
  **不设 locale 会让 Dart 拿到 `"C"`，播放器 l10n 解析失败**（托盘/文案异常）。
- **默认用户 `archoera`（uid 1000，家目录 `/home/archoera`）**：由
  `sysusers.d/zz-archoera.conf`（用户 + seat/tty/video/render/input/audio 组）与
  `tmpfiles.d/archoera.conf`（家目录、XDG 子目录、`~/Music`、并从
  `/usr/share/archoera/skel` **播种**初始配置——fcitx5 拼音 profile、
  `scan_dirs.json`）落地；目标已存在时不覆盖，数据随磁盘镜像持久保存。
- 自动登录（不再用 mkosi `Autologin=`，它只支持 root）：
  `getty@tty1.service.d/autologin.conf` → **archoera**；`serial-getty@hvc0.service.d/
  autologin.conf` → **root**（无头排查口，同时接收会话日志）。
  `/etc/profile.d/zz-archoera.sh` 在 tty1 上以**普通用户** `exec` 会话脚本；
  `/usr/local/bin/archoera-session` 循环启动合成器，日志默认写
  `~/.local/state/archoera-session.log`（内核把 `/dev/hvc0` 设为 0600 root:tty，
  普通用户不可写；无头排查时用 hvc0 的 root 口 `cat` 该文件即可）。会话客户端优先用真实播放器
  （`/opt/archoera-music/archoera_music`），缺失时回退 `archoera-smoke`。
  - 之所以必须是 **tty1（VT）**：systemd-logind 只对 VT 会话允许 `TakeControl`，
    串口会话会让 `libseat` 报 `Function not implemented`。
  - 以普通用户运行时，DRM/输入设备由 **libseat → logind** 的 VT 会话授权（与生产
    形态一致），不需要 root。
- `Ssh=yes`（VSock）：配合 `mkosi genkey` 可用 `mkosi ssh`（本环境实测未转发 stdout，
  仅作备用）。
- **光标主题**：`build.sh` 把宿主当前使用的 XCursor 主题（KDE `kcminputrc` /
  gsettings，缺省 Adwaita）复制进 `mkosi.extra/usr/share/icons/` 并写入
  `/opt/archoera/cursor-theme`；会话脚本据此导出 `XCURSOR_THEME`/`XCURSOR_SIZE`
  （已 gitignore，不入库）。
- **输入法**：会话脚本先起一个 session D-Bus，再等合成器 socket 出现后启动
  `fcitx5`（Wayland 前端以 `zwp_input_method_v2` 接入）。镜像含 `fcitx5` +
  `fcitx5-chinese-addons`，并预置启用拼音的 `/root/.config/fcitx5/profile`。

## 光标 / 输入法（合成器侧）

- 协议：`wl_pointer.set_cursor`、`zwp_cursor_shape_v1`（客户端直接请求命名形状）、
  `zwp_text_input_v3` + `zwp_input_method_v2`（输入法；smithay 负责两侧状态互转与
  键盘抓取，合成器只接全局对象、随键盘焦点自动 enter/leave、并把 IME 候选窗口
  用 `PopupManager` 跟踪后随窗口渲染）。
- 渲染顺序很关键：DRM 合成器的元素切片是**前 → 后（最上层在前）**，遇到
  「不透明且铺满输出」的元素会把其后的元素全部 skipped。光标必须放在**最前**，
  否则会被全屏应用窗口盖住（表现为「开机有指针、进应用后消失」）。
- 光标来源优先级：客户端 cursor surface → 命名形状（`XCURSOR_THEME` 主题，按
  `cursor_icon::CursorIcon::name()` 查 XCursor 名）→ 内置兜底位图
  （`resources/cursor.rgba`，`resources/gen_fallback_cursor.py` 生成）。
- 客户端给了**没有缓冲**的 cursor surface（典型：GTK 主题查找失败后仍调用
  `set_cursor`）时回退到命名默认光标，避免指针凭空消失。

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

### 真实播放器在 VM 内完整启动

```
[session] 启动 udev kiosk ... client='/opt/archoera-music/archoera_music'
已拉起会话客户端 pid=419 program="/opt/archoera-music/archoera_music"
Using the Impeller rendering backend (OpenGLESSDF).      ← Flutter 走 GLES/Impeller 出图
archoera_shell_v1 客户端已绑定 clients=1 capabilities=238 ← 会话桥接握手成功
[os] session=OsSessionState.ready
（随后稳定驻留：仅一次启动、无退出/重启）
```

已知降级（不影响启动与出图）：

- **[vault]** 无 Secret Service（只起了 session D-Bus，没有 keyring 守护进程），
  凭据保险库不可用（登录态不持久化）。
- `Gtk-CRITICAL gtk_widget_get_scale_factor` —— 无头/无窗口管理器会话下的无害告警。
- 光标/输入法已在 GUI 下人工验证：指针可见并随控件变化，fcitx5 可切拼音输入。

### 该 VM 暴露并修复的四个真实缺陷

1. **udev 未设置主输出**：`init_udev` 只把 `Output` 放进 `space`，没设
   `ArchoeraShell.output`，导致 `output_rect()` 恒为 `None`，kiosk 永不发 configure
   （客户端不绘制，只剩深色底 → 看起来像黑屏）。
2. **从不 flush 客户端事件**：winit 是在 `Redraw` 里 `flush_clients` 的，udev 路径没有；
   事件驱动之后 registry 全局 / configure / 帧回调都闷在缓冲里，客户端卡死
   （`registry_queue_init` 永不返回）。现于「客户端派发后」与「每帧渲染后」各冲刷一次。
3. **光标元素排在最底层**：DRM 合成器元素需**前 → 后**排列，光标被放到最后 →
   被不透明全屏窗口遮住（开机可见、进应用消失）。现光标前置。
4. **缺 `zwp_cursor_shape_v1`**：没有它时 GTK 走「按名字查主题」，而 Flutter 初始
   光标名是空串 → 加载失败 → GTK 仍发一个**没有缓冲**的 cursor surface → 指针消失。
   现注册该协议（GTK 直接请求命名形状），并在 surface 光标渲染为空时回退命名光标。

## 说明 / 限制

- **电源动作授权走 polkit**：logind 的 `power-off` / `reboot` / `suspend` / `hibernate`
  由 polkit 判定，默认策略 `allow_active=yes`（活动会话免鉴权，与普通桌面一致），
  故镜像需安装 `polkit`（已装并 enable）。会话脚本启动时会用 `pkcheck` 自检并打印
  `[session] polkit 授权: power-off = 允许` 等行，便于定位「点了没反应」。
  （kiosk 里没有 polkit 鉴权代理，因此不给 `archoera` 加 `wheel`；只依赖 allow_active。）
- 镜像已启用 BlueZ（`multi-user.target.wants` 符号链接由 tmpfiles 在首次启动创建；
  VM 无蓝牙适配器时 `bluetooth.service` 因 `ConditionPathIsDirectory=/sys/class/bluetooth`
  被跳过，桥接据此不置位蓝牙能力位，UI 不显示蓝牙分区）。
- 默认用户 `archoera`（uid 1000、`/home/archoera`）承载需要持久化的数据：
  `~/.local/share/ArchoeraMusic`（偏好/扫描目录/流媒体列表/下载）、`~/.config/fcitx5`、
  `~/.local/state`（会话日志）、`~/Music`（媒体库默认位置）。tty1 会话以该用户运行；
  `/dev/hvc0` 仍为 root 调试口。
- 首次启动 initrd 里可能有较长的 D-Bus 停止等待，引导偏慢；用**事件等待**
  （轮询串口日志出现关键标记）比固定 sleep 更省时。
- 目录镜像（`Format=directory`）需要 `ForeignUIDRange=yes` + 宿主
  `systemd-nsresourced`；本配置改用磁盘镜像规避。
- 迭代提速：日常只需 `mkosi --force build`（包已缓存）；只改 `mkosi.extra/` 时同样
  需要重建，但无需重新下载软件包。
