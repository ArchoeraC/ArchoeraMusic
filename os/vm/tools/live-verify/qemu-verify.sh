#!/bin/bash
# ArchoeraOS Live ISO 端到端验证（宿主侧，无需 root）：
#   1) 以光驱方式启动最终 ISO + 两块空白目标盘（vda / vdb）；
#   2) 通过 virtio 串口（hvc0，镜像里配了 root 自动登录）跑 guest-verify.sh：
#      - 启动状态自检（会话/网络/蓝牙/磁盘清单）；
#      - ext4 + 交换文件、不加密：安装并核对 fstab/hostname/locale/autologin/
#        machine-id/loader 条目/用户；
#      - btrfs + LUKS2：安装、luksDump、用口令打开并核对 crypttab 与
#        rd.luks.name 条目；
#      - 播放器 → 向导交接（写 request，确认客户端换成 ARCHOERA_MODE=installer）；
#   3) 关键节点用 monitor screendump 抓帧。
#
# 用法：os/vm 产物就绪后执行本脚本（默认用 os/vm/mkosi.output/archoera-live.iso）。
set -uo pipefail

REPO=/home/betastudio2/文档/SPlayer-Next/ArchoeraMusic
ISO="${1:-$REPO/os/vm/mkosi.output/archoera-live.iso}"
WORK=/tmp/opencode/iso-verify
MON=$WORK/mon.sock
SOCK=$WORK/serial.sock
mkdir -p "$WORK"
rm -f "$MON" "$SOCK"

echo "== ISO: $ISO"
ls -l "$ISO"
sha256sum "$ISO" | cut -c1-16

if [ ! -f "$WORK/OVMF_VARS.fd" ]; then
    cp /usr/share/edk2/x64/OVMF_VARS.4m.fd "$WORK/OVMF_VARS.fd" 2>/dev/null \
      || cp /usr/share/edk2/x64/OVMF_VARS.fd "$WORK/OVMF_VARS.fd"
fi
# 只留一块目标盘并顺序复用：目标镜像落在 /tmp（tmpfs=内存），多块大稀疏盘会把
# tmpfs 撑爆；每轮安装本来就会 wipefs + 重建分区表，复用是安全的（用户也要求
# 尽量用内存而不是让硬盘承受高强度写入）。
rm -f "$WORK"/vdb.qcow2 "$WORK"/vdc.qcow2 "$WORK"/vdd.qcow2
# 每轮重建：上一轮装出的系统会让这块盘变成可引导，OVMF 会优先从盘启动而非光驱。
qemu-img create -f qcow2 "$WORK/vda.qcow2" 12G >/dev/null

mon() { printf '%s\n' "$1" | timeout 10 socat - UNIX-CONNECT:"$MON" 2>/dev/null; }
shot() { mon "screendump $WORK/$1.ppm" >/dev/null; }
# 串口执行一条命令并读回显。
#   $1=命令  $2=总超时（默认 30s）  $3=命令后等待回显的秒数（默认 6s）
# 注意要先发一个空行「唤醒」agetty/readline，并给足回显时间：hvc0 上是
# 115200 的串口，短空闲超时（如 -T3）会在输出回来之前就断开。
ser() {
    local cmd="$1" total="${2:-30}" wait="${3:-6}"
    { sleep 0.5; printf '\n'; sleep 0.5; printf '%s\n' "$cmd"; sleep "$wait"; } \
        | timeout "$total" socat - UNIX-CONNECT:"$SOCK" 2>/dev/null | tr -d '\r'
}

echo "== 启动 QEMU（光驱 + 双目标盘）"
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
echo "qemu pid=$QPID"

cleanup() { kill "$QPID" 2>/dev/null || true; }
trap cleanup EXIT

echo "== 等待串口 root shell（首启要比后续慢）"
ready=0
for i in $(seq 1 90); do
    sleep 2
    out=$(ser "echo SER_READY_$(date +%s)" 25 5 || true)
    if printf '%s' "$out" | grep -q SER_READY_; then ready=1; break; fi
done
if [ "$ready" != 1 ]; then
    echo "!! 串口没有出现 shell；qemu 日志："; tail -20 "$WORK/qemu.log"
    exit 1
else
    echo "== 串口可用"
fi

shot 01-player
echo "== 抓帧：01-player.ppm（播放器 kiosk）"

echo "== 下发并后台执行 guest 验证脚本"
B64=$(base64 -w0 "$(dirname "$0")/guest-verify.sh")
ser "echo $B64 | base64 -d > /tmp/gv.sh && echo GUEST_SCRIPT_OK" 40 10 >/dev/null 2>&1
ser "setsid nohup bash /tmp/gv.sh > /tmp/gv.out 2>&1 < /dev/null & echo STARTED" 40 10 >/dev/null 2>&1

echo "== 轮询 guest 进度（安装是重活，耐心等）"
done_marker=0
for i in $(seq 1 300); do
    sleep 10
    tail_log=$(ser "tail -c 800 /tmp/gv.out 2>/dev/null" 35 12 || true)
    if printf '%s' "$tail_log" | grep -q __VERIFY_DONE__; then done_marker=1; break; fi
    if [ $((i % 6)) -eq 0 ]; then
        echo "--- 进度快照（$((i*10))s）"
        printf '%s\n' "$tail_log" | grep -E "=====|结果|message|已切到|ESP 布局" | tail -6
    fi
done

shot 02-after-handover
echo "== 抓帧：02-after-handover.ppm（应为安装向导）"

# 按键走几步向导（Tab 逐项聚焦、Enter 选择/前进），每轮抓一帧。
for i in 1 2 3 4; do
    for k in tab tab tab ret; do mon "sendkey $k" >/dev/null; sleep 0.4; done
    sleep 1.5
    shot "0$((i+2))-wizard-$i"
done

echo "== 取回 guest 日志"
ser "cat /tmp/gv.out" 180 60 > "$WORK/guest-output.txt" || true
sed -n '/===== 1)/,$p' "$WORK/guest-output.txt" | head -200

echo
echo "== 结论标记：$([ "$done_marker" = 1 ] && echo 'guest 脚本跑完 ✔' || echo 'guest 脚本超时 ✗')"
echo "日志：$WORK/guest-output.txt"
ls -l "$WORK"/*.ppm 2>/dev/null
