#!/bin/bash
# 在 Live 环境内（串口 root shell）跑的验证脚本：驱动安装器并核对产物。
# 由宿主侧 qemu-verify.sh 以 base64 送进来执行，输出写 /tmp/guest-verify.log。
set -u
STATE=/run/archoera-install
LOG=/tmp/guest-verify.log
: > "$LOG"
say() { echo "$@" | tee -a "$LOG"; }
have() { [ -e "$1" ] && echo "✔" || echo "✗"; }

say "===== 0) 启动状态自检 ====="
say "cmdline: $(cat /proc/cmdline)"
say "session=$(systemctl is-active archoera-session 2>/dev/null) NM=$(systemctl is-active NetworkManager 2>/dev/null) bt=$(systemctl is-active bluetooth 2>/dev/null) resolved=$(systemctl is-active systemd-resolved 2>/dev/null)"
say "候选磁盘清单:"; sed 's/^/  /' "$STATE/devices" 2>/dev/null | tee -a "$LOG"
say "网卡: $(ls /sys/class/net | tr '\n' ' ')"
say "initrd 生成器：dracut=$(have /usr/bin/dracut) mkinitcpio=$(have /usr/bin/mkinitcpio)"
say "kernel-install 配置: $(cat /etc/kernel/install.conf 2>/dev/null | grep -v '^#' | tr '\n' ' ')"
for b in mkfs.ext4 mkfs.btrfs mkfs.xfs mkfs.f2fs mkfs.fat; do
    say "  $b: $(have "/usr/bin/$b")"
done

wait_done() {
    local i
    for i in $(seq 1 300); do
        [ -f "$STATE/done" ] && return 0
        [ -f "$STATE/failed" ] && return 1
        sleep 2
    done
    return 2
}

# 装一个场景：$1=磁盘 $2=主机名 $3=fs $4=swap $5=encrypt
run_case() {
    local disk="$1" host="$2" fs="$3" swap="$4" enc="$5"
    # 复用同一块盘：先把上一轮的挂载与 LUKS 映射收干净（安装器自己会 wipefs）。
    for m in /mnt/esp /mnt/chk; do umount "$m" 2>/dev/null || true; done
    cryptsetup close chkroot 2>/dev/null || true
    say ""
    say "===== 安装：$disk（$fs / swap=$swap / encrypt=$enc）====="
    rm -f "$STATE/done" "$STATE/failed" "$STATE/percent" "$STATE/message"
    cat > "$STATE/plan" <<EOF
disk=$disk
hostname=$host
username=archoera
locale=zh_CN.UTF-8
timezone=Asia/Shanghai
keymap=cn
fs=$fs
swap=$swap
encrypt=$enc
autologin=1
EOF
    chmod 0600 "$STATE/plan"
    if [ "$enc" = "1" ]; then
        printf 'luks_passphrase=verify-pass-123\nuser_password=\nroot_password=\n' > "$STATE/secrets"
        chmod 0600 "$STATE/secrets"
    fi
    systemctl start archoera-install.service 2>&1 | tee -a "$LOG"
    if wait_done; then
        say "结果: 成功 ✔ percent=$(cat "$STATE/percent" 2>/dev/null)"
    else
        say "结果: 失败 ✗ → $(cat "$STATE/failed" 2>/dev/null)"; return 1
    fi
    say "message: $(cat "$STATE/message" 2>/dev/null)"
}

# 核对已安装系统：$1=根设备 $2=磁盘名 $3=标签
check_tree() {
    local dev="$1" disk="$2" tag="$3"
    local mnt=/mnt/chk esp=/mnt/esp
    mkdir -p "$mnt" "$esp"
    say "----- $tag -----"
    say "分区表: $(lsblk -no NAME,SIZE,FSTYPE "/dev/$disk" 2>/dev/null | tr '\n' '|')"
    if mount -o ro "$dev" "$mnt" 2>>"$LOG"; then
        say "fstab:"; sed 's/^/  /' "$mnt/etc/fstab" | tee -a "$LOG"
        say "crypttab: $(cat "$mnt/etc/crypttab" 2>/dev/null | grep -v '^#' | tr '\n' ' ')"
        say "kernel/cmdline: $(cat "$mnt/etc/kernel/cmdline" 2>/dev/null)"
        say "kernel/install.conf: $(grep -v '^#' "$mnt/etc/kernel/install.conf" 2>/dev/null | tr '\n' ' ')"
        say "dracut.conf.d: $(grep -v '^#' "$mnt/etc/dracut.conf.d/archoera.conf" 2>/dev/null | tr '\n' ' ' | cut -c1-120)"
        say "machine-id: $(cat "$mnt/etc/machine-id" 2>/dev/null)"
        say "hostname: $(cat "$mnt/etc/hostname" 2>/dev/null)  locale: $(cat "$mnt/etc/locale.conf" 2>/dev/null)"
        say "用户: $(grep -c '^archoera:' "$mnt/etc/passwd" 2>/dev/null) 个 archoera 条目"
        say "rm 守卫: $(have "$mnt/usr/local/bin/rm")"
        if [ "$3" = "btrfs-subvol" ]; then
            say "子卷列表:"; btrfs subvolume list "$mnt" 2>/dev/null | sed 's/^/  /' | tee -a "$LOG"
        fi
        umount "$mnt"
    else
        say "!! 无法挂载 $dev"
    fi
    if mount -o ro "/dev/${disk}1" "$esp" 2>>"$LOG"; then
        local mid kver
        mid="$(ls "$esp" 2>/dev/null | grep -E '^[0-9a-f]{32}$' | head -1)"
        say "ESP 布局: machine-id 目录=${mid:-缺失}"
        if [ -n "$mid" ]; then
            kver="$(ls "$esp/$mid" 2>/dev/null | head -1)"
            say "  $mid/$kver: $(ls "$esp/$mid/$kver" 2>/dev/null | tr '\n' ' ')"
            say "  linux=$(stat -c %s "$esp/$mid/$kver/linux" 2>/dev/null) 字节  initrd=$(stat -c %s "$esp/$mid/$kver/initrd" 2>/dev/null) 字节"
            say "  条目:"; cat "$esp/loader/entries/$mid-$kver.conf" 2>/dev/null | sed 's/^/    /' | tee -a "$LOG"
        fi
        say "  ESP 顶层: $(ls "$esp" 2>/dev/null | tr '\n' ' ')"
        say "  loader.conf: $(grep -v '^#' "$esp/loader/loader.conf" 2>/dev/null | tr '\n' ' ')"
        say "  EFI 回退路径: $(have "$esp/EFI/BOOT/BOOTX64.EFI")"
        # 若 kernel-install 的 BOOT_ROOT 判成了「根文件系统上的 /efi」，就会在这里露出来。
        say "  目标根下 /efi: $(ls "$mnt/efi" 2>/dev/null | tr '\n' ' ' | cut -c1-80)"
        say "  安装单元日志尾部:"; journalctl -u archoera-install.service -n 25 --no-pager 2>/dev/null | sed 's/^/    /' | tee -a "$LOG"
        umount "$esp"
    else
        say "!! 无法挂载 ESP /dev/${disk}1"
    fi
}

# GV_CASES=short 时只跑两个场景（改完安装器后做快速回归用）。
if [ "${GV_CASES:-all}" = "short" ]; then
    run_case /dev/vda verify-ext4 ext4 file 0 && check_tree /dev/vda2 vda "ext4 + 交换文件（不加密）"
    if run_case /dev/vda verify-btrfs-luks btrfs none 1; then
        say "LUKS 头: $(cryptsetup luksDump /dev/vda2 2>/dev/null | grep -E 'Version|PBKDF' | tr '\n' ' ')"
        if echo 'verify-pass-123' | cryptsetup open /dev/vda2 chkroot - 2>>"$LOG"; then
            check_tree /dev/mapper/chkroot vda "btrfs 子卷 + LUKS2"
            cryptsetup close chkroot
        fi
    fi
else
run_case /dev/vda verify-ext4 ext4 file 0 && check_tree /dev/vda2 vda "ext4 + 交换文件（不加密）"
run_case /dev/vda verify-xfs xfs none 0 && check_tree /dev/vda2 vda "xfs（不加密）"
run_case /dev/vda verify-f2fs f2fs none 0 && check_tree /dev/vda2 vda "f2fs（不加密）"
if run_case /dev/vda verify-btrfs-luks btrfs none 1; then
    say "LUKS 头: $(cryptsetup luksDump /dev/vda2 2>/dev/null | grep -E 'Version|PBKDF' | tr '\n' ' ')"
    if echo 'verify-pass-123' | cryptsetup open /dev/vda2 chkroot - 2>>"$LOG"; then
        check_tree /dev/mapper/chkroot vda "btrfs 子卷 + LUKS2"
        cryptsetup close chkroot
    else
        say "!! 口令打不开 LUKS"
    fi
fi

fi

say ""
say "===== rm 守卫（`rm -rf /*` 必须被拒绝）====="
rm -rf /archoera-guard-probe; say "根级路径删除: rc=$? （期望非 0=已拒绝）"
rm -rf --no-preserve-root /tmp/archoera-guard-probe2; say "--no-preserve-root: rc=$? （期望非 0）"
mkdir -p /tmp/archoera-guard-ok && rm -rf /tmp/archoera-guard-ok; say "正常多层级删除: rc=$? （期望 0）"

say ""
say "===== 播放器 → 安装向导交接 ====="
pid="$(pgrep -f archoera_music | head -1)"
say "写 request 前: $(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep ARCHOERA_MODE || echo '(player)')"
echo 1 > "$STATE/request"
for i in $(seq 1 30); do
    sleep 2
    pid="$(pgrep -f archoera_music | head -1)"
    if [ -n "$pid" ] && tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -q 'ARCHOERA_MODE=installer'; then
        say "已切到向导模式（pid=$pid）"; break
    fi
done
pid="$(pgrep -f archoera_music | head -1)"
say "最终: $(pgrep -a archoera_music | head -1) / $(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep ARCHOERA_MODE || echo '(player)')"
say ""
say "===== 验证结束 ====="
echo "__VERIFY_DONE__" >> "$LOG"
