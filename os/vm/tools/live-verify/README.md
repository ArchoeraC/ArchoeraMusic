# Live 介质的端到端验证工具

这些脚本用来在**本机（无需 root）**验证最终 Live ISO：光驱启动 → 串口 root shell
（`console=hvc0` + `serial-getty@hvc0` 自动登录）→ 自动跑安装/检查 → 抓帧与日志。

它们不是产品的一部分，但**每个都真的抓到过问题**（见下），所以留档并固化在这里，
避免每次重写。

## 前置

- 最终 ISO：`os/vm/mkosi.output/archoera-live.iso`（`os/vm/build.sh build --profile live` 产出）
- 依赖：`qemu-system-x86_64`、`qemu-img`、`socat`、`python3`（仅用于去掉串口 OSC 噪声）
- 需要 KVM；VM 内存默认 4G（`dracut` 在 chroot 里生成 initrd 比较吃内存/临时空间）

## 省盘原则（重要）

每次**全量重建**会写 ~17GB（mkosi 镜像树 + 6.4G raw + 4.7G ISO），对 SSD 很不友好。
绝大多数验证不需要重建：

- 安装器、dracut 配置、systemd 单元、polkit 规则 → 用 `live-shell.sh` 注入后直接试；
- 只有**包清单 / 内核 / initrd 生成方式**这类改动才真的需要 `build.sh`，且应**批量合并**后重建一次；
- 重建时把上一版 ISO 先删掉（别同时留两份 5G 产物）。

## 用法

```bash
# ① 文件系统对照实验（排查 xfs/f2fs 挂载失败）：wipefs→重建分区表→mkfs→mount
bash os/vm/tools/live-verify/fsexp-host.sh

# ② 安装器单场景调试（把工作区的 archoera-install 覆盖进 Live，带 ERR 陷阱/xtrace）
bash os/vm/tools/live-verify/installer-debug.sh

# ③ 完整验证：ext4(+交换) / xfs / f2fs / btrfs+LUKS2 依次装并核对产物
bash os/vm/tools/live-verify/qemu-verify.sh

# ④ 常驻 Live 会话（免重建迭代，推荐）：
bash os/vm/tools/live-verify/live-shell.sh
#   live> :put ./archoera-install /usr/local/bin/archoera-install
#   live> :putdir ../dracut.conf.d /etc/dracut.conf.d
#   live> systemctl start archoera-install
```

配套的 guest 侧脚本（`guest-*.sh`）由对应的 host 脚本以 base64 注入 Live，一般不用手改。

## 两个必须注意的坑（都踩过）

1. **每轮重建目标盘**：装过系统的盘会变成可引导，OVMF 之后会**优先从盘启动**而不是
   光驱 —— 于是你面对的「Live」其实是装好的系统（里面没有 `archoera-install.service`，
   `systemctl` 会报 not found，hostname/machine-id 也都是上一次安装的值）。
   脚本里已用 `qemu-img create` 重建 + `-boot order=d,once=d` 兜住。
2. **清理进程别用 `pkill -f` 匹配自己**：清理脚本的命令行里就含目标字样，会把自己杀掉
   （AGENTS 里明确警告过）。要清理就用 `pkill -x qemu-system-x86_64` 或按 PID。

## 抓到的真实问题（留作回归清单）

| 现象 | 真因 | 修复 |
|---|---|---|
| 安装永远「失败」且 `failed` 为空 | VM 从已装盘启动 → 单元不存在 → `systemctl` 失败；且安装器 `set -e` 退出时只留空文件 | 每轮重建盘 + 光驱优先；安装器加 `ERR` 陷阱与可选 xtrace |
| dracut 在 chroot 失败 → 无 initrd，安装却报 100% | 缺 `systemd-sysvcompat`（`poweroff/reboot/halt` 不在 systemd 本体） | 镜像加该包；安装器校验 initrd 真存在 |
| 串口没有 shell | Live cmdline 无 `console=hvc0`，systemd 只为 active console 起 `serial-getty@hvc0` | Live 条目加 `console=tty0 console=hvc0` |
| 装出来的系统引导条目带 "live" 字样 | `/etc/kernel/entry-token` 是 mkosi 写的 `archoera-live`，被 rsync 带进目标系统 | 目标系统删掉它 → 回落 machine-id |
| ISO 组装报「设备上没有空间」 | mkiso 默认工作目录在 `/tmp`（tmpfs），~600MB initrd 撑爆内存盘 | 默认改到 `~/.cache/archoera-mkiso`，FAT 容量按实际字节 + 64MiB |
