#!/bin/bash
# 常驻 Live 会话（免重建迭代）：启动一次 VM，之后从 stdin 读命令发到串口并回显。
#
# 用法（交互）：
#   os/vm/tools/live-verify/live-shell.sh
#   live> systemctl status NetworkManager
#   live> :put /path/on/host /usr/local/bin/archoera-install     # 注入文件（免重建）
#   live> :putdir /path/on/host/dir /etc/dracut.conf.d           # 注入目录（免重建）
#   live> :quit
#
# 用法（非交互 / 脚本里）：
#   printf '%s\n' ':put ...' 'kernel-install ...' | live-shell.sh
#
# 为什么有它：每次改动都全量重建 ISO 会写 ~17GB（mkosi 镜像 + raw + ISO），对 SSD
# 很不友好。绝大多数验证（安装器、dracut 配置、单元、polkit 规则…）都可以在 Live
# 里注入后直接试，只有「包清单/内核/initrd 生成方式」这类才真的需要重建。
set -uo pipefail
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
ISO="${ISO:-$REPO/os/vm/mkosi.output/archoera-live.iso}"
WORK="${WORK:-/tmp/opencode/live-shell}"
MON=$WORK/mon.sock
SOCK=$WORK/serial.sock
mkdir -p "$WORK"; rm -f "$MON" "$SOCK"

# 全新目标盘：装过系统的盘会被 OVMF 优先启动（那台系统里没有安装器单元）。
qemu-img create -f qcow2 "$WORK/vda.qcow2" 12G >/dev/null

ser() {  # $1=命令 $2=总超时 $3=回显等待
    local cmd="$1" total="${2:-40}" wait="${3:-8}"
    { sleep 0.4; printf '\n'; sleep 0.4; printf '%s\n' "$cmd"; sleep "$wait"; } \
        | timeout "$total" socat - UNIX-CONNECT:"$SOCK" 2>/dev/null | tr -d '\r'
}

clean() {  # 去掉串口上的 OSC/CSI 噪声
    python3 -c "
import sys,re
d=sys.stdin.read()
d=re.sub(r'\x1b\][^\x07]*\x07','',d); d=re.sub(r'\x1b\[[0-9;?]*[a-zA-Z]','',d)
print(d.replace('\r',''), end='')"
}

qemu-system-x86_64 -machine q35,accel=kvm -m 4096 -smp 2 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
  -drive if=pflash,format=raw,file="$WORK/OVMF_VARS.fd" \
  -drive file="$ISO",media=cdrom,readonly=on,format=raw \
  -drive file="$WORK/vda.qcow2",if=virtio,format=qcow2 \
  -boot order=d,once=d \
  -display none -device virtio-gpu-pci -device virtio-keyboard-pci \
  -monitor unix:"$MON",server=on,wait=off \
  -device virtio-serial-pci \
  -chardev socket,id=ser0,path="$SOCK",server=on,wait=off \
  -device virtconsole,chardev=ser0 \
  >"$WORK/qemu.log" 2>&1 &
QPID=$!
trap 'kill $QPID 2>/dev/null' EXIT

for i in $(seq 1 60); do
    sleep 2
    ser "echo LIVE_READY_$RANDOM" 20 4 | grep -q LIVE_READY_ && break
done
echo "[live-shell] 已连上串口（pid=$QPID）。命令直接打；:put/:putdir 注入；:quit 退出。" >&2

while IFS= read -r line; do
    case "$line" in
        :quit|:q) break ;;
        :put\ *)
            set -- $line; host="${2:?用法: :put <宿主文件> <Live 路径>}"; guest="${3:?}"
            b64=$(base64 -w0 "$host")
            ser "echo $b64 | base64 -d > $guest && ls -l $guest && echo PUT_OK" 120 15 | clean | tail -4
            ;;
        :putdir\ *)
            set -- $line; host="${2:?用法: :putdir <宿主目录> <Live 目录>}"; guest="${3:?}"
            b64=$(tar -C "$host" -czf - . | base64 -w0)
            ser "echo $b64 | base64 -d | tar -xzf - -C $guest && ls -l $guest | head -6 && echo PUTDIR_OK" 180 20 | clean | tail -8
            ;;
        '') continue ;;
        *)  ser "$line" 90 10 | clean | tail -40 ;;
    esac
done
echo "[live-shell] 退出（VM 关闭）。" >&2
