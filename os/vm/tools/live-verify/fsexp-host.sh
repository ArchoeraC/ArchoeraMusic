#!/bin/bash
# 启动 Live，跑 guest-fsexp.sh（wipefs→重建分区表→mkfs→mount 对照实验），取回输出。
set -uo pipefail
REPO=/home/betastudio2/文档/SPlayer-Next/ArchoeraMusic
ISO="$REPO/os/vm/mkosi.output/archoera-live.iso"
WORK=/tmp/opencode/iso-verify
MON=$WORK/mon.sock
SOCK=$WORK/serial.sock
mkdir -p "$WORK"; rm -f "$MON" "$SOCK"
# 全新目标盘（装过系统的盘会被 OVMF 优先启动）
qemu-img create -f qcow2 "$WORK/vda.qcow2" 12G >/dev/null

ser() {
    local cmd="$1" total="${2:-30}" wait="${3:-6}"
    { sleep 0.5; printf '\n'; sleep 0.5; printf '%s\n' "$cmd"; sleep "$wait"; } \
        | timeout "$total" socat - UNIX-CONNECT:"$SOCK" 2>/dev/null | tr -d '\r'
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
    out=$(ser "echo READY_$(date +%s)" 25 4 || true)
    printf '%s' "$out" | grep -q READY_ && { echo "== 串口可用"; break; }
done

B64=$(base64 -w0 "$(dirname "$0")/guest-fsexp.sh")
ser "echo $B64 | base64 -d > /tmp/fx.sh && wc -c /tmp/fx.sh && echo FX_READY" 90 12 >/dev/null 2>&1
ser "setsid nohup bash /tmp/fx.sh > /tmp/fx.out 2>&1 < /dev/null & sleep 2; echo FX_STARTED" 60 10 >/dev/null 2>&1

for i in $(seq 1 40); do
    sleep 10
    t=$(ser "grep -c __EXP_DONE__ /tmp/fx.out 2>/dev/null; tail -c 400 /tmp/fx.out" 35 10 || true)
    printf '%s' "$t" | grep -q "__EXP_DONE__" && break
done

echo "================ 实验结果 ================"
ser "cat /tmp/fx.out" 150 45 \
  | python3 -c "
import sys,re
d=sys.stdin.read()
d=re.sub(r'\x1b\][^\x07]*\x07','',d); d=re.sub(r'\x1b\[[0-9;?]*[a-zA-Z]','',d); d=d.replace('\r','')
print(d)" | grep -vE "^\[root@|^$" | tail -80
