#!/bin/bash
# ArchoeraOS Live 内的「mkfs → mount」对照实验（排查 xfs/f2fs 挂载失败）。
#
# 在 Live 的串口 root shell 里跑（宿主侧由 fsexp-host.sh 注入并执行）。
# 目的：区分三种可能
#   ① mkfs 根本没写成（工具/参数问题）
#   ② mkfs 写了但内核因缓存/分区表陈旧看不到（wipefs/重建分区表路径问题）
#   ③ 写成了、也读得到，但内核不支持该 fs 的某个特性
set -u
DISK=/dev/vda
MNT=/mnt/t
mkdir -p "$MNT"

repart() {
    umount "$MNT" 2>/dev/null || true
    wipefs -a "$DISK" >/dev/null 2>&1
    sfdisk --wipe always "$DISK" >/dev/null 2>&1 <<EOF
label: gpt
name=ESP, size=1G, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
name=ArchoeraOS, type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709
EOF
    blockdev --rereadpt "$DISK" 2>/dev/null || true
    partprobe "$DISK" 2>/dev/null || true
    udevadm settle || true
    echo "  分区: $(lsblk -no NAME,SIZE,FSTYPE "$DISK" 2>/dev/null | tr '\n' '|')"
}

try() {  # $1=名字 $2..=mkfs
    local name="$1"; shift
    echo "===== $name ====="
    repart
    echo "  mkfs:"; "$@" 2>&1 | tail -3 | sed 's/^/    /'
    echo "  mkfs rc=${PIPESTATUS[0]}"
    echo "  lsblk -f: $(lsblk -no FSTYPE,LABEL,UUID "${DISK}2" 2>&1 | tr '\n' ' ')"
    echo "  blkid: $(blkid "${DISK}2" 2>&1)"

    # 变体 1：mkfs 后直接挂载
    if mount "${DISK}2" "$MNT" 2>&1 | sed 's/^/    /'; then
        echo "  mount 直接 → OK ✔"; umount "$MNT"; return 0
    fi
    echo "  mount 直接 → 失败 ✗"

    # 变体 2：flush 缓冲后再挂载（验证「内核缓存陈旧」假设）
    sync; blockdev --flushbufs "${DISK}2" 2>/dev/null || true
    if mount "${DISK}2" "$MNT" 2>&1 | sed 's/^/    /'; then
        echo "  mount(flushbufs 后) → OK ✔ ← 说明是缓冲区/缓存陈旧"; umount "$MNT"; return 0
    fi
    echo "  mount(flushbufs 后) → 仍失败 ✗"

    # 变体 3：按类型显式挂载，看内核的精确原因
    echo "  mount -t $name 输出: $(mount -t "$name" "${DISK}2" "$MNT" 2>&1 | tail -1)"
    echo "  dmesg 尾部:"; dmesg | tail -8 | sed 's/^/    /'

    # 变体 4：用 fs 自己的工具回读，判断「本体是否合法」
    case "$name" in
        xfs)  command -v xfs_db >/dev/null && { echo "  xfs_db:"; xfs_db -r -c 'sb 0' -c 'print magicnum' -c 'print blocksize' -c 'print sectsize' "${DISK}2" 2>&1 | head -5 | sed 's/^/    /'; } ;;
        f2fs) command -v fsck.f2fs >/dev/null && { echo "  fsck.f2fs 回读:"; fsck.f2fs -f -n "${DISK}2" 2>&1 | head -8 | sed 's/^/    /'; } ;;
    esac
    return 1
}

try ext4 mkfs.ext4 -F -q -L ArchoeraOS "${DISK}2"
try xfs  mkfs.xfs  -f    -L ArchoeraOS "${DISK}2"
try f2fs mkfs.f2fs -f    -l ArchoeraOS "${DISK}2"
echo "__EXP_DONE__"
