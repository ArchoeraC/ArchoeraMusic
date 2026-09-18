#!/bin/bash
# 免重建的调试环：启动 Live → 把工作区里的 archoera-install 覆盖进 Live →
# 带 xtrace 跑一次 ext4 安装 → 取回失败行/trace/journal。
set -uo pipefail
REPO=/home/betastudio2/文档/SPlayer-Next/ArchoeraMusic
INSTALLER="$REPO/os/vm/mkosi.profiles/live/live-extra/usr/local/bin/archoera-install"
ISO="$REPO/os/vm/mkosi.output/archoera-live.iso"
WORK=/tmp/opencode/iso-verify
MON=$WORK/mon.sock
SOCK=$WORK/serial.sock
mkdir -p "$WORK"; rm -f "$MON" "$SOCK"
# 每轮重建目标盘：装过系统的盘是可引导的，OVMF 会优先从它启动而不是光驱。
qemu-img create -f qcow2 "$WORK/vda.qcow2" 12G >/dev/null

mon() { printf '%s\n' "$1" | timeout 10 socat - UNIX-CONNECT:"$MON" 2>/dev/null; }
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
echo "qemu pid=$QPID"

ready=0
for i in $(seq 1 60); do
    sleep 2
    out=$(ser "echo SER_READY_$(date +%s)" 25 5 || true)
    if printf '%s' "$out" | grep -q SER_READY_; then ready=1; break; fi
done
if [ "$ready" != 1 ]; then echo "!! 串口起不来"; tail -5 "$WORK/qemu.log"; exit 1; fi
echo "== 串口可用"

echo "== 覆盖 Live 里的安装器（带 on_err / xtrace）"
B64=$(base64 -w0 "$INSTALLER")
ser "echo $B64 | base64 -d > /usr/local/bin/archoera-install && chmod 0755 /usr/local/bin/archoera-install && echo INSTALLER_OVERWRITTEN" 90 15 >/dev/null 2>&1
ser "grep -c on_err /usr/local/bin/archoera-install" 30 6 | tail -2

echo "== 下发并后台执行调试脚本"
GB64=$(base64 -w0 "$(dirname "$0")/guest-debug.sh")
ser "echo $GB64 | base64 -d > /tmp/gd.sh && wc -c /tmp/gd.sh && echo GD_READY" 60 10 | tail -3

echo "== 后台执行调试脚本"
ser "setsid nohup env GV_FS=${GV_FS:-ext4} bash /tmp/gd.sh > /tmp/gd.log 2>&1 < /dev/null & sleep 2; echo \"GD_STARTED fs=${GV_FS:-ext4}\"" 60 12 | tail -3

echo "== 轮询（安装约 3-6 分钟）"
for i in $(seq 1 60); do
    sleep 10
    t=$(ser "tail -c 1200 /tmp/gd.log 2>/dev/null" 35 12 || true)
    printf '%s' "$t" | grep -q __GD_DONE__ && break
    [ $((i % 6)) -eq 0 ] && { echo "--- ${i}0s"; printf '%s\n' "$t" | tail -3; }
done

echo
echo "================ 完整调试输出 ================"
ser "cat /tmp/gd.log; echo '--- gd.out ---'; cat /tmp/gd.out; echo '--- trace ---'; tail -40 /run/archoera-install/trace; echo '--- failed ---'; cat /run/archoera-install/failed" 180 60 \
  | python3 -c "import sys,re; d=sys.stdin.read(); d=re.sub(r'\x1b\\][^\x07]*\x07','',d); d=re.sub(r'\x1b\\[[0-9;?]*[a-zA-Z]','',d); d=d.replace('\r',''); print(d)" \
  | grep -vE "^\[root@|^$" | tail -150
