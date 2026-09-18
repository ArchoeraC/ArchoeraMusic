#!/bin/bash
# 启动「已安装到磁盘的系统」并验证它真的能起来（终极验证）。
#
# 背景：安装器把 cmdline 写成 `console=tty0 console=hvc0`，因此装出来的系统
# 在串口（hvc0）上有 root 自动登录 shell —— 既方便无头核对，也让 LUKS 口令
# 可以在串口里输入。
#
# 用法：
#   boot-installed.sh [磁盘镜像] [LUKS 口令]
#   默认磁盘 /tmp/opencode/iso-verify/vda.qcow2（installer-debug.sh 装出来的那块），
#   默认无口令（未加密安装）。加密安装示例：
#   boot-installed.sh /tmp/opencode/iso-verify/vda.qcow2 verify-pass-123
#
# 只写内存：目标盘是 /tmp（tmpfs）里的 qcow2，不写 SSD。
set -uo pipefail
IMG="${1:-/tmp/opencode/iso-verify/vda.qcow2}"
LUKS_PASS="${2:-}"
WORK="${WORK:-/tmp/opencode/boot-installed}"
MON=$WORK/mon.sock
SOCK=$WORK/serial.sock
mkdir -p "$WORK"; rm -f "$MON" "$SOCK"
[ -f "$IMG" ] || { echo "找不到磁盘镜像：$IMG（先用 installer-debug.sh 装一次）" >&2; exit 1; }
# OVMF 变量盘：每个工作目录都要有一份可写的（缺了 QEMU 会直接退出，脚本会空转）。
if [ ! -f "$WORK/OVMF_VARS.fd" ]; then
    cp /usr/share/edk2/x64/OVMF_VARS.4m.fd "$WORK/OVMF_VARS.fd" 2>/dev/null \
      || cp /usr/share/edk2/x64/OVMF_VARS.fd "$WORK/OVMF_VARS.fd"
fi

ser() {
    local cmd="$1" total="${2:-30}" wait="${3:-8}"
    { sleep 0.4; printf '\n'; sleep 0.4; printf '%s\n' "$cmd"; sleep "$wait"; } \
        | timeout "$total" socat - UNIX-CONNECT:"$SOCK" 2>/dev/null | tr -d '\r'
}
clean() {
    python3 -c "
import sys,re
d=sys.stdin.read()
d=re.sub(r'\x1b\][^\x07]*\x07','',d); d=re.sub(r'\x1b\[[0-9;?]*[a-zA-Z]','',d)
print(d.replace('\r',''), end='')"
}
mon() { printf '%s\n' "$1" | timeout 10 socat - UNIX-CONNECT:"$MON" 2>/dev/null; }
shot() { mon "screendump $WORK/$1.ppm" >/dev/null; }

# 只挂目标盘、磁盘优先启动（不带光驱，避免又跑成 Live）。
qemu-system-x86_64 -machine q35,accel=kvm -m 4096 -smp 2 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
  -drive if=pflash,format=raw,file="$WORK/OVMF_VARS.fd" \
  -drive file="$IMG",if=virtio,format=qcow2 \
  -boot order=c \
  -display none -device virtio-gpu-pci -device virtio-keyboard-pci \
  -monitor unix:"$MON",server=on,wait=off \
  -device virtio-serial-pci \
  -chardev socket,id=ser0,path="$SOCK",server=on,wait=off \
  -device virtconsole,chardev=ser0 \
  >"$WORK/qemu.log" 2>&1 &
QPID=$!
trap 'kill $QPID 2>/dev/null' EXIT
echo "qemu pid=$QPID  盘=$IMG  LUKS 口令=${LUKS_PASS:-(无)}"

booted=0
for i in $(seq 1 30); do
    # QEMU 起不来/中途死了要立刻报，否则就是空等 90 秒（踩过：OVMF_VARS 缺失）。
    if ! kill -0 "$QPID" 2>/dev/null; then
        echo "!! QEMU 已退出：" >&2; tail -5 "$WORK/qemu.log" >&2; exit 1
    fi
    sleep 6
    shot "boot-$(printf '%02d' "$i")"
    out=$(ser "echo BOOTPROBE_$RANDOM" 25 5 || true)
    # LUKS：initrd 会在 active console（hvc0）上提示输入口令
    if printf '%s' "$out" | grep -qiE 'passphrase|password for'; then
        if [ -z "$LUKS_PASS" ]; then
            echo "!! 出现 LUKS 口令提示，但没给口令；请带第二参数重跑" >&2
            exit 1
        fi
        echo "== 检测到 LUKS 口令提示，输入口令…"
        ser "$LUKS_PASS" 60 15 | clean | tail -5
        continue
    fi
    if printf '%s' "$out" | grep -q BOOTPROBE_; then booted=1; break; fi
    [ $((i % 3)) -eq 0 ] && echo "… 等待启动（$((i*6))s）"
done

if [ "$booted" != 1 ]; then
    echo "!! 90s 内没有在串口拿到 shell；可能卡在引导/解锁（见 $WORK/boot-*.ppm 与 qemu.log）" >&2
    tail -5 "$WORK/qemu.log" >&2
    exit 1
fi
echo "== 串口拿到 shell，已启动 ✔  开始核对 =="

ser "hostnamectl --static; echo ---; cat /proc/cmdline; echo '--- 挂载 ---'; \
     findmnt -no SOURCE,FSTYPE,OPTIONS /; \
     for d in /home /opt /var/log /var/cache; do findmnt -no SOURCE,FSTYPE,OPTIONS \$d 2>/dev/null || echo \"\$d: 未单独挂载\"; done; \
     echo '--- crypttab/LUKS ---'; cat /etc/crypttab 2>/dev/null; cryptsetup status cryptroot 2>/dev/null | head -6; \
     echo '--- 引导 ---'; ls /boot/ 2>/dev/null; ls /boot/*/ 2>/dev/null | head -8; \
     echo '--- 会话 ---'; systemctl is-system-running; \
     for u in archoera-session graphical.target NetworkManager bluetooth systemd-resolved; do echo \"\$u: \$(systemctl is-active \$u 2>/dev/null)\"; done; \
     echo '--- 播放器 ---'; ls -l /opt/archoera-music/archoera_music 2>/dev/null; \
     echo '--- pacman ---'; pacman -Q systemd systemd-sysvcompat dracut 2>/dev/null" 180 45 | clean | tail -70

shot "boot-final"
echo
echo "抓帧：$WORK/boot-*.ppm（可用 python3 -c \"from PIL import Image;Image.open('…ppm').save('…png')\" 转换）"
