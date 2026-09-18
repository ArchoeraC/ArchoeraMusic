#!/usr/bin/env bash
# 用 xorriso 把 mkosi 产出的 Live 镜像重打包成「标准 ISO」。
#
# 为什么需要它：mkosi 的 El Torito 目录指向镜像内的 ESP 分区，Ventoy/光盘把 ISO 当
# CD（2048 字节扇区）暴露时，镜像里的 GPT 分区对内核不可见 → 卡在设备枚举。
#
# 标准形态（与 archiso 同构）：
#   - root = ISO9660 本身（只读）+ systemd.volatile=overlay（tmpfs 可写层）；
#   - El Torito 载荷是一个**小 FAT 映像**（efiboot.img），里面放 systemd-boot
#     以及**内核与 initrd 本体** —— 关键：systemd-boot 只在它自己所在的卷里解析
#     条目的 linux/initrd 路径（archiso 就是这么做的：/arch/boot/... 在 FAT 里），
#     把内核留在 ISO9660 上会导致静默失败并回退固件菜单；
#   - 同一套引导文件也放在 ISO9660 的相同路径下，便于 Ventoy/其它引导器读取；
#   - xorriso `-z`（zisofs 透明压缩）显著缩小 ISO 体积（内核支持 CONFIG_ZISOFS=y）。
#
# 用法：os/vm/mkiso.sh [live 镜像路径]
#   默认：mkosi.output/archoera-live.raw（需先用 build.sh build --profile live 构建）
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IMG="${1:-$HERE/mkosi.output/archoera-live.raw}"
# 产物落盘位置可覆盖：构建耗盘（树/root/EFI/ISO 加起来 ~15G），把它指到大容量挂载点
# 或内存盘可以避免反复磨损系统盘，例如：
#   MKISO_OUT=/run/media/<user>/<card>/archoera-live.iso MKISO_WORK=/tmp/mkiso os/vm/mkiso.sh
OUT="${MKISO_OUT:-$HERE/mkosi.output/archoera-live.iso}"
# 工作目录：默认放**磁盘**缓存而不是 /tmp —— /tmp 往往是 tmpfs（内存），
# 而这里要落 ~600MB 的 initrd、~650MB 的 efiboot.img 与整棵 rootfs 树，
# 在 tmpfs 上会把内存吃光并报「设备上没有空间」。需要换位置用 MKISO_WORK=...
WORK="${MKISO_WORK:-${XDG_CACHE_HOME:-$HOME/.cache}/archoera-mkiso}"
VOLID=ARCHOERA_LIVE

[ -f "$IMG" ] || { echo "找不到 Live 镜像：$IMG（先跑 build.sh build --profile live）" >&2; exit 1; }

# ── 1) 读取分区布局 ────────────────────────────────────────────────
mapfile -t PARTS < <(sfdisk -d "$IMG" | sed -n 's/^[^:]*raw\([12]\) : start= *\([0-9]*\), size= *\([0-9]*\).*/\1 \2 \3/p')
read -r _ ESP_START ESP_SIZE <<<"${PARTS[0]}"
read -r _ ROOT_START ROOT_SIZE <<<"${PARTS[1]}"
echo "==> 分区：ESP start=$ESP_START size=$ESP_SIZE；root start=$ROOT_START size=$ROOT_SIZE"

# ── 2) 抽出 root 与 ESP，导出 root 文件树 ──────────────────────────
# 注意：mkosi 重新构建后镜像会变新，这里的缓存必须失效重导，否则会一直用旧树
# （症状：改 mkosi.extra / live-extra 里的东西永远进不去 ISO）。
mkdir -p "$WORK"
ROOT_IMG="$WORK/root.ext4"
TREE="$WORK/tree"
if [ ! -f "$ROOT_IMG" ] || [ "$IMG" -nt "$ROOT_IMG" ]; then
    echo "==> 抽取 root 分区（$((ROOT_SIZE/2048))MiB）…"
    dd if="$IMG" of="$ROOT_IMG" bs=512 skip="$ROOT_START" count="$ROOT_SIZE" status=none
fi
if [ ! -d "$TREE" ] || [ "$ROOT_IMG" -nt "$TREE/etc/os-release" ]; then
    echo "==> 用 debugfs 导出 root 文件树（保持权限位）…"
    # rdump 会保留 0444/0555 权限，直接 rm -rf 会因只读目录失败：先放开属主写权限。
    if [ -d "$TREE" ]; then
        chmod -R u+rwX "$TREE" 2>/dev/null || true
        rm -rf "$TREE" || true
    fi
    mkdir -p "$TREE"
    debugfs -R "rdump / $TREE" "$ROOT_IMG" >/dev/null 2>&1 || true
    [ -e "$TREE/etc/os-release" ] || { echo "导出 root 文件树失败" >&2; exit 1; }
fi

# ── 3) 取引导文件（内核 / 微码 / initrd） ───────────────────────────
# 必须用 mkosi 的「三件套」并合成**单个** initrd：
#   - `/*/microcode.initrd`：早期微码 cpio；
#   - `/*/initrd`：mkosi wrapper initramfs（systemd/udev + 按 modules-load.d 显式
#     加载的模块；**不含** isofs/overlay，也没有模块元数据）；
#   - `/*/*/kernel-modules.initrd`：全模块 + `modules.alias`/`modules.dep`
#     （`sr_mod`/`usb-storage` 等要靠它才能按 modalias 自动加载）。
# 只用 ESP 根目录的 `initramfs-linux.img` 时没有模块元数据 → udev 加载不了 sr_mod
# → 永远没有 `/dev/sr0`/root 设备（实测卡在 by-label 等待）。
# 合成方式：先解开压缩成员，再裸 cpio 拼接后**整体**压成一个归档。直接 `cat`
# 「压缩成员 + 裸 cpio」会被内核解压器吞掉（实测），所以不能简单拼接。
ESP_IMG="$WORK/esp.img"
# ⚠ 必须和 root 一样带新鲜度判断：ESP 里放着内核/microcode/initrd/模块 initrd 与
# systemd-boot。若只在「文件不存在」时抽取，重建后仍会拿**上一版**的 initrd 合成
# ISO —— 表现为「改了 initrd 配置但怎么验证都没变化」（实测踩过：esp.img 停在几小时前，
# 期间所有验证用的都是旧 initrd）。
if [ ! -f "$ESP_IMG" ] || [ "$IMG" -nt "$ESP_IMG" ]; then
    echo "==> 抽取 ESP（$((ESP_SIZE/2048))MiB）…"
    dd if="$IMG" of="$ESP_IMG" bs=512 skip="$ESP_START" count="$ESP_SIZE" status=none
fi
BOOT="$WORK/boot"           # 引导文件暂存（稍后同时写进 FAT 与 ISO9660）
SPLIT="$WORK/split"
mkdir -p "$BOOT" "$SPLIT"
# 清掉上一版可能留下的旧引导文件（脚本管理的目录，避免把旧 initrd 也打进 ISO）
rm -rf "$TREE/archoera/boot"
mkdir -p "$TREE/archoera/boot"
# ⚠ 所有 mcopy 都要 `</dev/null`：mtools 会打开 /dev/tty 做交互确认（覆盖/异常时），
# 在脚本里没有终端输入就**永久挂住**（实测：卡 12 分钟、0% CPU、wchan=wait_woken）。
copy_esp() { mcopy -o -i "$ESP_IMG" "::$1" "$2" </dev/null 2>/dev/null; }
echo "==> 取内核 / 微码 / 模块 initrd（三件套）…"
copy_esp /vmlinuz-linux "$SPLIT/vmlinuz" || { echo "ESP 里没有 vmlinuz-linux" >&2; mdir -i "$ESP_IMG" -a ::/ >&2; exit 1; }
copy_esp "/*/microcode.initrd" "$SPLIT/microcode.initrd" || { echo "缺 microcode.initrd" >&2; exit 1; }
copy_esp "/*/initrd"           "$SPLIT/initrd"           || { echo "缺 initrd" >&2; exit 1; }
mcopy -o -i "$ESP_IMG" "::/*/*/kernel-modules.initrd" "$SPLIT/kernel-modules.initrd" </dev/null 2>/dev/null \
    || { echo "缺 kernel-modules.initrd" >&2; exit 1; }
copy_esp /EFI/BOOT/BOOTX64.EFI "$SPLIT/BOOTX64.EFI" || { echo "ESP 里没有 BOOTX64.EFI" >&2; exit 1; }

# 每次都重建（~30-60s）：缓存判断不可靠（源 initrd 变化时容易留下旧的，必须重合成）
echo "==> 合成单个 initrd（解开压缩成员 → 裸 cpio 拼接 → 整体 zstd）…"
zstd -dc "$SPLIT/initrd" > "$SPLIT/initrd.raw" 2>/dev/null || cp "$SPLIT/initrd" "$SPLIT/initrd.raw"

# 追加 Live 专用的 initrd 扩展（root 设备兜底：Ventoy 正常模式下自己去找 ISO 文件）。
# 注意必须在**整体压缩之前**以裸 cpio 拼接：压缩成员后面接裸 cpio 会被内核解压器吞掉。
EXTRA_SRC="$HERE/live-initrd-extra"
EXTRA_CPIO="$WORK/initrd-extra.cpio"
: > "$EXTRA_CPIO"
if [ -d "$EXTRA_SRC" ]; then
    rm -rf "$WORK/initrd-extra"; mkdir -p "$WORK/initrd-extra"
    cp -a "$EXTRA_SRC/." "$WORK/initrd-extra/"
    chmod 0755 "$WORK/initrd-extra/usr/lib/archoera/iso-locate"
    # initrd 里没有 systemctl：直接建 wants 符号链接来 enable
    mkdir -p "$WORK/initrd-extra/usr/lib/systemd/system/initrd-root-device.target.wants"
    ln -sf ../archoera-iso-locate.service \
        "$WORK/initrd-extra/usr/lib/systemd/system/initrd-root-device.target.wants/archoera-iso-locate.service"
    (cd "$WORK/initrd-extra" && find . -mindepth 1 | cpio -o -H newc --quiet) > "$EXTRA_CPIO"
    echo "    已加入 initrd 扩展：$(du -sh "$EXTRA_CPIO" | cut -f1)"
fi

# 早期固件：mkosi 生成的 initrd 只按「模块依赖」带固件，实测缺 Intel AX201 蓝牙所需的
# `intel/ibt-0040-*`（只有 ibt-11-5/12-16），且 FirmwareInclude 也扩不到 modules initrd →
# 真机表现为「无蓝牙适配器」。这里直接从镜像树把蓝牙/无线/有线固件目录补进合成 initrd。
FW_CPIO="$WORK/initrd-fw.cpio"
FW_ROOT="$WORK/initrd-fw"
rm -rf "$FW_ROOT"; mkdir -p "$FW_ROOT"
# 注意 `intel/ibt-*` 是**文件名前缀**（ibt-0040-*.sfi 等是文件，不是目录），
# 而 `intel/iwlwifi`、`rtl_nic` 等是目录 —— 统一按 glob 展开后复制。
for pat in "intel/ibt-*" "intel/iwlwifi" "rtl_bt" "rtl_nic" "mediatek" "qca"; do
    for src in $TREE/usr/lib/firmware/$pat; do
        [ -e "$src" ] || continue
        rel="${src#"$TREE/usr/lib/firmware/"}"
        mkdir -p "$FW_ROOT/usr/lib/firmware/$(dirname "$rel")"
        cp -a "$src" "$FW_ROOT/usr/lib/firmware/$(dirname "$rel")/"
    done
done
(cd "$FW_ROOT" && find . -mindepth 1 | cpio -o -H newc --quiet) > "$FW_CPIO"
echo "    已补早期固件：$(du -sh "$FW_CPIO" | cut -f1)"

cat "$SPLIT/microcode.initrd" "$SPLIT/initrd.raw" "$SPLIT/kernel-modules.initrd" \
    "$EXTRA_CPIO" "$FW_CPIO" \
    | zstd -T0 -3 -f -o "$BOOT/initramfs-linux.img"
cp "$SPLIT/vmlinuz" "$BOOT/vmlinuz"
cp "$SPLIT/BOOTX64.EFI" "$BOOT/BOOTX64.EFI"
ls -la "$BOOT"

# ── 4) 小 EFI FAT 映像（El Torito 载荷）：systemd-boot + 内核 + initrd ──
EB="$WORK/efiboot.img"
mkdir -p "$WORK"
AVAIL_KB=$(df -Pk "$WORK" | awk 'NR==2{print $4}')
if [ "${AVAIL_KB:-0}" -lt $((8 * 1024 * 1024)) ]; then
    echo "!! $WORK 可用空间不足 8GiB（当前 $(( ${AVAIL_KB:-0} / 1024 / 1024 ))GiB）" >&2
    echo "   可换位置：MKISO_WORK=/path/to/disk/cache $0" >&2
    exit 1
fi

echo "==> 生成 EFI 启动映像 $EB（含内核与 initrd）…"
# 容量 = 引导文件**实际字节数** + 64MiB 余量（FAT32 表/簇开销 + 对齐）。
# ⚠ 不要用 du -sm 的块占用：initrd 已 ~600MB，四舍五入与簇开销会顶到边界
# 而报「设备上没有空间 / fat_write failed」。
_sz() { stat -c %s "$1" 2>/dev/null || echo 0; }
NEED=$(( ( $(_sz "$BOOT/BOOTX64.EFI") + $(_sz "$BOOT/vmlinuz") \
           + $(_sz "$BOOT/initramfs-linux.img") + 1048575 ) / 1048576 + 64 ))
SIZE=$NEED
rm -f "$EB"; truncate -s "${SIZE}M" "$EB"
mkfs.fat -F32 -n ARCHOERAEFI "$EB" >/dev/null

STAGE="$WORK/efi"
rm -rf "$STAGE"; mkdir -p "$STAGE/EFI/BOOT" "$STAGE/loader/entries" "$STAGE/archoera/boot"
cp "$BOOT/BOOTX64.EFI" "$STAGE/EFI/BOOT/BOOTX64.EFI"
for f in vmlinuz initramfs-linux.img; do
    [ -f "$BOOT/$f" ] && cp "$BOOT/$f" "$STAGE/archoera/boot/$f"
done
cat > "$STAGE/loader/loader.conf" <<EOF
default archoera.conf
timeout 0
editor no
EOF
ENTRY="$STAGE/loader/entries/archoera.conf"
{
    echo "title   ArchoeraOS Live"
    echo "linux   /archoera/boot/vmlinuz"
    echo "initrd  /archoera/boot/initramfs-linux.img"
    # ⚠ console=tty0 与 console=hvc0 都要显式给：systemd 只为「active console」
    # 实例化 serial-getty@hvc0，而镜像里那份 root 自动登录 drop-in 正是挂在
    # serial-getty@hvc0 上的 —— 不给 console=hvc0 就永远不会有人监听串口，
    # 无头排查口等于不存在（本次验证就是踩了这个）。
    echo "options root=LABEL=$VOLID rootfstype=iso9660 splash plymouth.ignore-serial-consoles console=tty0 console=hvc0 systemd.volatile=overlay archoera.live=1 systemd.firstboot=no"
} > "$ENTRY"
echo "--- $ENTRY"; cat "$ENTRY"
mcopy -o -s -i "$EB" "$STAGE/EFI"      ::/ </dev/null
mcopy -o -s -i "$EB" "$STAGE/loader"   ::/ </dev/null
mcopy -o -s -i "$EB" "$STAGE/archoera" ::/ </dev/null

# 同一套文件也放 ISO9660（Ventoy/其它能读 ISO9660 的引导器用；路径与 FAT 内一致）
cp -a "$STAGE/EFI"     "$TREE/"
cp -a "$STAGE/loader"  "$TREE/"
cp -a "$STAGE/archoera" "$TREE/"
cp "$EB" "$TREE/EFI/BOOT/efiboot.img"
# ISO 当 root：清掉原镜像的 fstab（里面写的是镜像内 PARTUUID，对 ISO 不适用）
: > "$TREE/etc/fstab"
# ISO 根只读 → systemd 无法生成 machine-id：预置一个有效的（32 位十六进制），
# 否则每次开机都触发 systemd-firstboot 文本向导、占住 tty1，kiosk 起不来。
tr -d '-' < /proc/sys/kernel/random/uuid > "$TREE/etc/machine-id.tmp"
chmod 0444 "$TREE/etc/machine-id.tmp"
mv -f "$TREE/etc/machine-id.tmp" "$TREE/etc/machine-id" 2>/dev/null \
    || { chmod u+w "$TREE/etc/machine-id"; cp "$TREE/etc/machine-id.tmp" "$TREE/etc/machine-id"; rm -f "$TREE/etc/machine-id.tmp"; }

# ── 4b) 权限修补 ────────────────────────────────────────────────────
# debugfs rdump 以普通用户导出时会丢掉 setuid/sgid（内核不允许非属主置位），
# ISOfs(Rock Ridge) 能存这些位，所以按 Arch 的 canonical 模式补回来；
# 同时给「属主无读」的文件（如 dbus-daemon-launch-helper 04110）加属主读，
# 否则 xorriso 无法读取该文件而整体失败。存在才设，缺失静默跳过。
echo "==> 修补 setuid/sgid 与属主可读性…"
for spec in \
    "usr/bin/su 4755" "usr/bin/passwd 4755" "usr/bin/chfn 4755" "usr/bin/chsh 4755" \
    "usr/bin/gpasswd 4755" "usr/bin/newuidmap 4755" "usr/bin/newgidmap 4755" \
    "usr/bin/mount 4755" "usr/bin/umount 4755" "usr/bin/expiry 2755" \
    "usr/lib/dbus-daemon-launch-helper 4510" \
    "usr/lib/polkit-1/polkit-agent-helper-1 4755" \
    "usr/lib/utempter/utempter 2755"; do
    # shellcheck disable=SC2086
    set -- $spec
    [ -e "$TREE/$1" ] && chmod "$2" "$TREE/$1" || true
done
find "$TREE" -type f ! -readable -exec chmod u+r {} + 2>/dev/null || true
echo "    setuid/sgid 文件数：$(find "$TREE" -type f -perm /6000 2>/dev/null | wc -l)"

# ── 5) xorriso 组装（zisofs 透明压缩 + El Torito EFI + isohybrid）──
echo "==> xorriso 组装 ISO（-z 透明压缩）…"
rm -f "$OUT"
xorriso -as mkisofs \
    -iso-level 3 -full-iso9660-filenames -R -J -joliet-long \
    -z -uid 0 -gid 0 \
    -V "$VOLID" -A "ArchoeraOS" -p "ArchoeraOS" \
    -eltorito-alt-boot -e EFI/BOOT/efiboot.img -no-emul-boot \
    -isohybrid-gpt-basdat \
    -o "$OUT" "$TREE" 2>&1 | tail -5

ls -la "$OUT" 2>/dev/null && echo "==> 完成：$OUT"
echo "    dd 到 U 盘：dd if=$OUT of=/dev/sdX bs=4M status=progress oflag=sync"
