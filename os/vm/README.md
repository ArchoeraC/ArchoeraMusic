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

# 构建并启动 VM（自动补 virtio-gpu / 键盘 / 触摸板 / 多点触摸）
os/vm/build.sh vm
```

镜像为 `Format=disk`（`mkosi.output/archoera-kiosk.raw`，2G 稀疏）。`udev` 后端需要
真实 DRM 设备，因此 `vm` 会透传 `-device virtio-gpu-pci`（mkosi 仅在 `Console=gui`
时自带 GPU）与输入设备：`virtio-keyboard-pci` / `virtio-tablet-pci` /
`virtio-multitouch-pci`（多点触摸，供触摸与屏幕键盘验证）。RAM 默认 2G（≤ 4G）。

## Live 介质 / 标准 ISO（`mkiso.sh`）

Live 镜像（`build.sh build --profile live`）产出的是 **mkosi 混合镜像**：El Torito 引导项
指向镜像内的 ESP **分区**。Ventoy/光盘把 ISO 当 CD（2048 字节扇区）暴露时，镜像里的 GPT
分区对内核不可见 → 卡在设备枚举（`root=PARTUUID` 永不出现）。

`os/vm/mkiso.sh` 用 **xorriso** 把它重打包成**标准 ISO**（与 archiso 同构）：

```bash
os/vm/build.sh build --profile live     # mkosi 构建（收尾会自动调用 mkiso.sh）
# 单独对已有镜像组装（中间产物可缓存复用，加速迭代）：
MKISO_WORK=~/.cache/archoera-mkiso os/vm/mkiso.sh mkosi.output/archoera-live.raw
```

- **root = ISO9660 本身**（只读）+ `systemd.volatile=overlay`（tmpfs 可写层）：
  内核参数 `root=LABEL=ARCHOERA_LIVE rootfstype=iso9660`，不再依赖镜像内 `PARTUUID`，
  因此 Ventoy 的「CD 暴露」方式也能挂上 root。
- **El Torito 载荷是一个小 FAT 映像**（`EFI/BOOT/efiboot.img`），里面同时放
  **systemd-boot、`loader/entries/archoera.conf`、以及内核与 initrd 本体**。
  ⚠ **关键**：systemd-boot 只在**它自己所在的卷**里解析条目的 `linux`/`initrd` 路径。
  把内核留在 ISO9660 上会「静默失败」——固件启动项一闪，直接回退固件菜单
  （实测 OVMF 打印 `BdsDxe: starting Boot0002 "UEFI QEMU DVD-ROM"` 之后无任何输出，
  随后进入 `Reboot Into Firmware Interface` 倒计时）。archiso 同理：它的 El Torito
  FAT 里就带着 `/arch/boot/x86_64/vmlinuz-linux` + `initramfs-linux.img`。
- 同一套引导文件也放在 **ISO9660 的相同路径**（`/archoera/boot/**`、`/EFI/BOOT/BOOTX64.EFI`、
  `/loader/**`），便于 Ventoy/其它能读 ISO9660 的引导器。
- `xorriso -z`（zisofs **透明压缩**）：6.2G 混合镜像 → ~3.9G ISO。内核
  `CONFIG_ZISOFS=y` 直接透明解压，无需自定义 initrd/hook。
- 引导用 mkosi 的**三件套**合成**单个** initrd（`microcode.initrd` + `initrd` +
  `<kver>/kernel-modules.initrd`）：只有 `kernel-modules.initrd` 带模块元数据
  （`modules.alias`/`modules.dep`），缺它 udev 就无法按 modalias 加载 `sr_mod`/
  `usb-storage` 等 → 光驱 `/dev/sr0` 永不出现 → 卡在 `by-label` 等待
  （`initramfs-linux.img` 正是没有模块元数据的那一个）。
  ⚠ 合成必须「先解开压缩成员 → 裸 cpio 拼接 → 再整体压成一个归档」；直接 `cat`
  「压缩成员 + 裸 cpio」会被内核解压器吞掉（实测失败），三件套分三段传也有同样风险。
- ISO 根只读：**必须预置有效的 `/etc/machine-id`**（脚本写入 32 位十六进制），否则
  `systemd-firstboot` 每次开机都会占住 tty1 跑文本向导（镜像里该文件是 `uninitialized`），
  kiosk 永远起不来；entry 另加 `systemd.firstboot=no` 兜底。安装器会在目标盘**重新生成**
  有效 machine-id（`systemd-machine-id-setup --root=`）——留空会让装出来的系统首启再弹一次向导。
- 实测（QEMU/KVM，最终 ISO）：**光驱** ~20~40s 进 kiosk（10s 出播放器启动画面）、
  **Ventoy 正常模式**（USB exFAT 分区里放 ISO）~20~50s，日志为
  `命中 ISO: … → /dev/loop0` → `Found device /dev/disk/by-label/ARCHOERA_LIVE` → `Mounted /sysroot`；
  光驱/dd 路径下定位单元直接跳过（`by-label 已出现，跳过扫描`），零额外延迟。
- **Ventoy「正常模式」兜底**：Ventoy 用它自己的 grub 从 ISO 里取出内核/initrd 直接启动，
  但**不会**给 booted 内核留下指向该 ISO 的块设备 → `root=LABEL=` 会一直等不到。
  为此合成 initrd 里追加了 `archoera-iso-locate.service`（源码在
  `os/vm/live-initrd-extra/`，`mkiso.sh` 以**裸 cpio** 拼进合成 initrd）：先认 archiso 风格的
  `img_dev=`/`img_loop=`，否则扫描本地分区（含 Ventoy 的 exFAT 分区）里的 `*.iso`，
  用 `blkid` 核对卷标后 `losetup` 挂上 → udev 生成 `by-label` 链接（带重试，USB 枚举有时间差）。
  光驱/dd 启动时 `by-label` 早已存在，该单元会被 `ConditionPathExists` 跳过，不产生开销。
- **已验证全链路**（QEMU/KVM + OVMF，`-drive media=cdrom`）：固件 → El Torito FAT 里的
  systemd-boot → 内核 → 合成 initrd → `root=LABEL=ARCHOERA_LIVE rootfstype=iso9660`
  + `systemd.volatile=overlay` → 进 kiosk（真实播放器界面）。

### 引导目录形态（不必手工改）

EDK2 的 `MdeModulePkg/Universal/Disk/PartitionDxe/ElTorito.c` 表明：固件**不检查
platform 字节**（只看 `0x88` 指示字与 `LBA != 0`），且 **`SectorCount < 2` 时按
「整个 CD 区」建立子设备**。因此 xorriso 写出的 `validation platform=0xEF`、
`SectorCount=0`、no-emulation 的目录完全可用——无需手工改成
「validation=0x00 + section header 0xEF」的形态。用 QEMU 以**光驱**方式验证：

```bash
qemu-system-x86_64 -machine q35,accel=kvm -m 2048 -smp 2 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
  -drive if=pflash,format=raw,file=/tmp/OVMF_VARS.fd \
  -drive file=mkosi.output/archoera-live.iso,media=cdrom,readonly=on,format=raw \
  -display none -device virtio-gpu-pci -device virtio-keyboard-pci
```

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
  `fcitx5`（Wayland 前端以 `zwp_input_method_v2` + `zwp_virtual_keyboard_v1` 接入）。
  镜像含 `fcitx5` + `fcitx5-chinese-addons`，并预置启用拼音的 `/root/.config/fcitx5/profile`。

## 光标 / 输入法（合成器侧）

- 协议：`wl_pointer.set_cursor`、`zwp_cursor_shape_v1`（客户端直接请求命名形状）、
  `zwp_text_input_v3` + `zwp_input_method_v2`（输入法；smithay 负责两侧状态互转与
  键盘抓取，合成器只接全局对象、随键盘焦点自动 enter/leave、并把 IME 候选窗口
  用 `PopupManager` 跟踪后随窗口渲染）。
- **`zwp_virtual_keyboard_v1` 必需**：fcitx5 的 Wayland 前端在初始化输入上下文前
  会同时查找 `zwp_input_method_v2` 与 `zwp_virtual_keyboard_v1`；只有前者时它不会
  抓取键盘，表现为「无法切换输入法」。合成器注册该全局后 fcitx5 才会真正接管键盘，
  Ctrl+Space 切拼音/中英生效；未被 IME 消费的按键再由它经虚拟键盘转发给客户端。
- **触摸**：座位提供 `wl_touch`。触摸按下即命中窗口、置顶并把键盘焦点交给它，
  使 `zwp_text_input_v3` / `zwp_input_method_v2` 激活——触摸设备常无物理键盘，
  播放器内置 OSK 据此在触摸聚焦输入框时弹出（见 `app/lib/widgets/common/touch_keyboard/`）。
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
archoera_shell_v1 客户端已绑定 clients=1 capabilities=750 ← 会话桥接握手成功（含 keyboard）
[os] session=OsSessionState.ready
（随后稳定驻留：仅一次启动、无退出/重启）
```

已知降级（不影响启动与出图）：

- **[vault]** 无 Secret Service（只起了 session D-Bus，没有 keyring 守护进程），
  凭据保险库不可用（登录态不持久化）。
- `Gtk-CRITICAL gtk_widget_get_scale_factor` —— 无头/无窗口管理器会话下的无害告警。
- 光标/输入法/触摸已在 GUI 下人工验证：指针可见并随控件变化，fcitx5 可切拼音输入；
  触摸聚焦输入框会弹出播放器内置 OSK，其按键与物理键盘同路径（IME 可消费）。

### 该 VM 暴露并修复的六个真实缺陷

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
5. **缺 `zwp_virtual_keyboard_v1`**：fcitx5 的 Wayland 前端**同时**要求
   `zwp_input_method_v2` 与 `zwp_virtual_keyboard_v1` 才会初始化输入上下文，缺后者时
   它不抓取键盘 → 快捷键切不了输入法。现注册该全局，并供播放器 OSK 注入按键。
6. **座位无 `wl_touch`、触摸不聚焦**：触摸设备上无法点选输入框、键盘焦点不转移，
   `zwp_text_input_v3` / `zwp_input_method_v2` 不激活。现 `seat.add_touch()` 并让
   触摸按下命中窗口 + 置顶 + 置键盘焦点；配合播放器内置 OSK 形成完整触摸输入闭环。

## 说明 / 限制

- **开机/关机画面：Plymouth**（`Packages=plymouth`）。主题
  `mkosi.extra/usr/share/plymouth/themes/archoera/`（深色底 `#0E1117` + 品牌 logo
  （自 `logo.png` 提亮）+ 细进度条；系统未上报进度时呼吸脉冲，开机早期与关机阶段都有动效），
  默认主题写在 `mkosi.extra/etc/plymouth/plymouthd.conf`。
  - 单元 enablement：Arch 的 `plymouth-*.service` **没有 `[Install]`**（标准流程靠 initrd 的
    `poweroff/reboot.target.wants`），我们用 mkosi-initrd，故在 `tmpfiles.d` 里建同名符号链接：
    `sysinit.target.wants/plymouth-start`、`multi-user.target.wants/plymouth-quit(-wait)`、
    `poweroff.target.wants/plymouth-poweroff`、`reboot.target.wants/plymouth-reboot`。
    DRM 交接由 systemd 保证（`getty@tty1.service` 自带 `After=plymouth-quit-wait.service`）。
  - **内核参数必须加 `plymouth.ignore-serial-consoles`**：我们以 `console=hvc0` 收日志，
    Plymouth 检测到串口会给所有显示强制文本 details 主题（实测日志
    `serial consoles detected, managing them with details forced`），加了这条才会用图形主题。
  - 实测（QEMU `screendump` 抓帧）：开机与重启/关机均出现主题画面（深底 + logo + 进度条），
    随后正常交接给合成器；串口日志不受影响。
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
