#!/bin/bash
# 在 Live 里带 trace 跑一次安装（宿主会先把新版 archoera-install 覆盖进去）。
set -u
STATE=/run/archoera-install
say() { echo "$@"; }

touch "$STATE/debug"          # 开 xtrace → $STATE/trace
rm -f "$STATE/done" "$STATE/failed" "$STATE/percent" "$STATE/message" "$STATE/trace"

FSKIND="${GV_FS:-ext4}"
cat > "$STATE/plan" <<EOF
disk=/dev/vda
hostname=dbg-${FSKIND}
username=archoera
locale=zh_CN.UTF-8
timezone=Asia/Shanghai
keymap=cn
fs=${FSKIND}
swap=none
encrypt=0
autologin=1
EOF
chmod 0600 "$STATE/plan"

say "=== 安装器版本自检 ==="
grep -c "on_err" /usr/local/bin/archoera-install || true

say "=== 宿主侧状态核对 ==="
say "hostname=$(hostname)  /etc/hostname=$(cat /etc/hostname 2>/dev/null | head -1)"
say "vda 分区: $(lsblk -no NAME,SIZE,FSTYPE /dev/vda 2>/dev/null | tr '\n' '|')"

say "=== 直接跑安装器（fs=${FSKIND}，前台，输出到 /tmp/gd.out）==="
grep -n "FSKIND\|^fs=" "$STATE/plan" | head -3
/usr/local/bin/archoera-install > /tmp/gd.out 2>&1
say "安装器退出码=$?"
say "--- gd.out 尾部 ---"; tail -30 /tmp/gd.out | sed 's/^/  /' 

say "=== 结果 ==="
say "done=$([ -f "$STATE/done" ] && echo yes || echo no) failed=$([ -f "$STATE/failed" ] && echo yes || echo no)"
say "percent=$(cat "$STATE/percent" 2>/dev/null)  message=$(cat "$STATE/message" 2>/dev/null)"
say "failed 内容："; cat "$STATE/failed" 2>/dev/null | sed 's/^/  /'

say "=== trace 尾部 60 行 ==="
tail -60 "$STATE/trace" 2>/dev/null | sed 's/^/  /'

say "=== journal 尾部 30 行 ==="
journalctl -u archoera-install.service -n 30 --no-pager 2>/dev/null | tail -30 | sed 's/^/  /'

say "=== ESP 与目标系统核对 ==="
mkdir -p /mnt/esp /mnt/root
if mount -o ro /dev/vda1 /mnt/esp 2>/dev/null; then
    say "ESP 顶层: $(ls /mnt/esp | tr '\n' ' ')"
    say "loader.conf: $(grep -v '^#' /mnt/esp/loader/loader.conf 2>/dev/null | tr '\n' ' ')"
    for e in /mnt/esp/loader/entries/*.conf; do
        [ -f "$e" ] && { say "条目 $(basename "$e"):"; sed 's/^/  /' "$e"; }
    done
    find /mnt/esp -maxdepth 3 -name initrd -o -maxdepth 3 -name 'linux' 2>/dev/null | while read -r f; do
        say "  $f: $(stat -c %s "$f") 字节"
    done
    umount /mnt/esp
fi
if mount -o ro /dev/vda2 /mnt/root 2>/dev/null; then
    say "fstab:"; sed 's/^/  /' /mnt/root/etc/fstab
    say "cmdline: $(cat /mnt/root/etc/kernel/cmdline 2>/dev/null)"
    say "machine-id: $(cat /mnt/root/etc/machine-id 2>/dev/null)"
    say "hostname: $(cat /mnt/root/etc/hostname 2>/dev/null)"
    umount /mnt/root
fi

say "__GD_DONE__"
