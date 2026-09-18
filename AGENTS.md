# AGENTS.md — ArchoeraMusic 维护与发布指引

本文件面向在本仓库工作的 AI 助手与维护者，记录**发布/签名**等关键流程。
通用贡献规范见 `CONTRIBUTING.md`。

## Git 认证与提交签名（优先密钥方案）
- **优先使用 SSH + GPG 密钥**：`origin` 使用 SSH（`git@github.com:<owner>/<repo>.git`）认证，
  提交使用 GPG 签名，不依赖 Personal Access Token（PAT）/账号密码。
- **若发现用户仍在使用 token**（remote 为 `https://...`、配置了存 token 的 `credential.helper`、
  或需要输入 PAT 才能 push），应**主动建议其更换为密钥方案**（SSH 认证 + GPG 签名），并说明：
  token 易泄露、权限过宽、需定期轮换；密钥可细粒度控制且可签名验证来源。
- **期望配置**（`git config --global`）：
  `user.signingkey <GPG key id>`、`commit.gpgsign true`、`tag.gpgsign true`；
  remote 使用 SSH，推送无需 token。
- **验证**：`ssh -T git@github.com`（应回显用户名）；`git log --show-signature -1`（签名有效）。
- **红线**：禁止把 token、私钥写入仓库、脚本或 remote URL；凭据只保存在本地密钥环。

## 构建与测试（提交前必跑）
```bash
cd app
flutter pub get
dart analyze lib            # 0 issue
flutter test                # 全绿
```
改动原生模块（`app/core/audio-engine`）时另跑：
```bash
cd app/core/audio-engine
zig build -Doptimize=ReleaseFast
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j
cd build && ctest
```
改动平台桥接（`app/native/platform`）时另跑：
```bash
cmake -S app/native/platform -B app/native/platform/build -DCMAKE_BUILD_TYPE=Release
cmake --build app/native/platform/build -j
```

改动 ArchoeraOS 会话层（`os/`，Rust workspace）时另跑：
```bash
cd os
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cargo check -p archoera-shell --features udev   # 需 libseat/libdrm/gbm/libinput/libudev 开发文件
```
CI 见 `.github/workflows/os-ci.yml`（改动 `os/**` 时自动触发）。

改动 Live 介质（`os/vm/`，mkosi profile `live`）时另跑：
```bash
os/vm/build.sh build --profile live        # mkosi 构建 → 收尾自动调 mkiso.sh 组装标准 ISO
# 只重组装（中间产物缓存在 MKISO_WORK，迭代快很多）：
MKISO_WORK=~/.cache/archoera-mkiso os/vm/mkiso.sh os/vm/mkosi.output/archoera-live.raw
```
产物必须用 QEMU 以**光驱**方式（不是 U 盘 dd、也不是 `-kernel` 直启）验证能进 kiosk：
```bash
qemu-system-x86_64 -machine q35,accel=kvm -m 2048 -smp 2 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
  -drive if=pflash,format=raw,file=/tmp/OVMF_VARS.fd \
  -drive file=os/vm/mkosi.output/archoera-live.iso,media=cdrom,readonly=on,format=raw \
  -display none -device virtio-gpu-pci -device virtio-keyboard-pci
```
- 这是 Linux，不是 Windows：QEMU/KVM 下从固件到进 kiosk 一般 **10~15 秒**（2G RAM 也够）。
  验证时按秒级节奏抓帧/看串口，**不要**动辄 sleep 几分钟或设超长 timeout；
  超过 ~30 秒还没到会话就当作失败，直接去查串口/日志，别干等。

## 架构约定（务必遵守）

### 系统调用统一走 C++ 桥接器
- **所有平台/系统能力**（媒体会话、电源/防休眠、窗口状态、系统主题色、通知、单实例、
  以及未来任何系统集成）**一律在 `app/native/platform`（C++/ObjC++）实现**；
  Dart 只通过 `apl_*` C ABI（`dart:ffi`）调用。
- **禁止 Dart 直接调平台 API**：不得用 MethodChannel/平台插件、不得 `Process.run` 起系统命令/子进程、
  不得在 Dart 侧解析平台数据（坚持零 JSON、零子进程、同进程动态链接）。
- **最小权限（普通用户可完成）**：所有系统调用必须能在**普通用户**权限下完成——
  程序**不得要求管理员/root 权限**：不请求 UAC 提权、不写 `HKLM`/系统目录/需提权的位置、
  不安装服务或驱动、不注册需提权的系统资源。需要提权才能实现的能力**放弃或降级**，
  不做"请以管理员身份运行"的设计（否则一律视为不符合规范）。
  - **唯一例外：Windows 安装向导（`packaging/windows/archoera_music.iss`）的可选
    per-machine 模式**。向导可提供「仅为我安装（默认 `%LOCALAPPDATA%\Programs`，全程免提权）」
    与「为所有用户安装（默认 `Program Files`，需用户在向导内显式选择并经 UAC 提权）」两种模式，
    **默认必须是 per-user 免提权**。提权只允许发生在安装/卸载向导内且由用户显式确认；
    更新旧版时必须沿用其原有安装模式，模式不一致时以失败退出。
  - 上述例外**不适用于应用运行时**：`app/` 与 `app/native/platform` 仍一律不得请求提权，
    也不得写 `HKLM`/系统目录（per-machine 的 `HKLM` 写入只能由向导在提权后完成）。
- **新增能力流程**：`include/archoera_platform.h` 扩 ABI → `core.*` / `backend.h` 加契约 →
  三端后端各实现（`backend_windows.cpp` / `backend_linux.cpp` / `backend_macos.mm`；
  未覆盖平台落 `backend_stub.cpp`）→ Dart 绑定（`app/lib/services/platform/`）→
  各平台构建脚本/打包依赖同步（详见 `docs/platform-native-bridge.md`）。
- 桥接器**按平台官方工具链原生编译**：Windows MSVC C++/WinRT、Linux C++ + libdbus + dlopen GTK、
  macOS ObjC++；**不要再引入 Zig 承载桥接**。

### 模块化
- 按职责拆文件、单一职责，避免巨型文件（桥接器即范例：`core` / `backend` / `apl` + 每平台一个后端文件）。
- 跨平台共享逻辑放共享层（`core.*` / `backend.h`），平台特有逻辑放各平台文件；新增平台只加一个后端文件。
- 新增/修改功能时同样适用：先想清楚归属与拆分，再落代码。

### Live 介质：只认标准 ISO
- Live 交付物是 **xorriso 组装的标准 ISO**（`os/vm/mkiso.sh`），不是 mkosi 混合镜像：
  后者的 El Torito 指向镜像内 ESP 分区，Ventoy/光盘以 CD（2048 字节扇区）暴露时镜像内
  GPT 不可见 → `root=PARTUUID` 永不出现。
- root 必须是 **ISO9660 本身** + `systemd.volatile=overlay`（`root=LABEL=ARCHOERA_LIVE
  rootfstype=iso9660`）：不要依赖镜像内的分区或 `PARTUUID`。
- **El Torito 载荷（小 FAT 映像）里必须同时放 systemd-boot、`loader/entries/*.conf`
  与内核/initrd 本体**，并在 ISO9660 上以相同路径再放一份（供 Ventoy/其它引导器）。
  systemd-boot 只在**自己所在的卷**解析条目的 `linux`/`initrd`：把内核留在 ISO9660 会
  「静默失败」——固件启动项一闪即回退固件菜单（archiso 同理，其 EFI 映像里自带
  `/arch/boot/x86_64/vmlinuz-linux` + `initramfs-linux.img`）。
- 引导用 mkosi 的**三件套**合成**单个** initrd：`microcode.initrd`（早期微码）+
  `initrd`（wrapper initramfs）+ `<kver>/kernel-modules.initrd`（全模块 + 模块元数据）。
  只有后者带 `modules.alias`/`modules.dep`：缺它 udev 无法按 modalias 自动加载
  `sr_mod`/`usb-storage` 等 → 光驱 `/dev/sr0` 永不出现 → 卡在等 `by-label`
  （`initramfs-linux.img` 没有模块元数据，单用它就是这个问题）。
  ⚠ 合成必须是「**先解开压缩成员 → 裸 cpio 拼接 → 再整体压成一个归档**」：
  直接 `cat` 压缩成员 + 裸 cpio 会被内核解压器吞掉（实测三件套分三段传同样有此风险）。
- **initrd 必须显式强制带上「早期就枚举」设备所需的模块**：mkosi-initrd 的 `KernelModules=`
  未列出的模块会被当作**可选而直接排除，连同其依赖的固件一起**不进 initrd。蓝牙/网卡/无线
  正是在 initrd 阶段就枚举并 probe 的，缺了它们真机就表现为「无蓝牙适配器 / 上不了网」
  （Intel AX201 需要 `intel/ibt-0040-*`，实测只带上了 ibt-11-5/12-16）。
  故 `mkosi.initrd.conf` 强制列出 `btusb`/`btintel`/`btrtl`/`btbcm`/`btmtk`/`bluetooth`/
  `r8169`/`iwlwifi`/`iwlmvm`；`mkiso.sh` 另把 `intel/ibt`、`intel/iwlwifi`、`rtl_bt`、
  `rtl_nic`、`mediatek`、`qca` 固件目录直接补进合成 initrd 兜底（不依赖 mkosi 固件语义）。
  固件路径备忘：Intel 无线在顶层 `iwlwifi-*` **与** `intel/iwlwifi/`；Intel 蓝牙 `intel/ibt-*`；
  Realtek 有线 `rtl_nic/*`、蓝牙 `rtl_bt/*`。
- **不要在 `mkosi.extra` 里放单元 `.wants` 符号链接**：mkosi 拷入时会丢掉符号链接（实测镜像里
  根本不存在，`multi-user.target.wants/NetworkManager.service` 等都没有）。enable 单元一律用
  **普通文件 drop-in**（`/etc/systemd/system/<target>.d/*.conf` 里的 `Wants=`），或既有
  tmpfiles 规则兜底。
- 压缩只用 xorriso `-z`（zisofs 透明压缩，内核 `CONFIG_ZISOFS=y`）：不要引 squashfs 或
  自定义 initrd hook。
- `mkfs.fat -n` 卷标 ≤ 11 字符。EDK2 固件不检查 El Torito platform 字节，且 `SectorCount < 2`
  视为「整个 CD 区」——无需手工改写引导目录形态。
- ISO 根只读 → 必须**预置有效的 `/etc/machine-id`**（32 位十六进制）：镜像里它是
  `uninitialized`，缺了会让 `systemd-firstboot` 每次开机占住 tty1 跑文本向导，kiosk 起不来。
  entry 里再加 `systemd.firstboot=no` 兜底。
  **安装器同理**：目标盘必须**重新生成**一个有效 machine-id（`systemd-machine-id-setup --root=`），
  不能只是清空——留空会让装出来的系统首启又弹同一个向导。
- **Ventoy「正常模式」兜底**：Ventoy 用它自己的 grub 从 ISO 取内核/initrd 直接启动，
  但**不会**给 booted 内核留下该 ISO 的块设备 → `root=LABEL=` 等不到。故合成 initrd 里
  追加 `archoera-iso-locate.service`（源码 `os/vm/live-initrd-extra/`，`mkiso.sh` 以裸 cpio
  拼入）：先认 archiso 风格 `img_dev=`/`img_loop=`，否则扫描本地分区（含 Ventoy 的 exFAT）
  里的 `*.iso`，`blkid` 核对卷标后 `losetup` 挂上 → udev 生成 `by-label` 链接（带重试，
  USB 枚举有时间差）。光驱/dd 启动时 `by-label` 早已存在，该单元会被 `ConditionPathExists`
  跳过，不产生开销。
- 验证基线（QEMU/KVM，都是最终 ISO 实测）：**光驱** ~20~40s 进 kiosk、**USB/Ventoy** ~20~50s；
  真机通常更快。若卡在 `by-label` 等待或文本向导，按上文查缺模块元数据 / machine-id / ISO 定位。

### 渲染与性能
- **高渲染压力优先 GPU**：着色器/滤镜/合成走 GPU（Flutter `FragmentProgram`/shader、Skia/Impeller），
  不要在 Dart 主 isolate 做逐像素或重计算。
- 重计算/阻塞 IO 下沉到后台 isolate 或原生层；UI 线程只做轻量调度。
- 新增/修改功能同样先问"能不能 GPU 化 / 下沉原生"，再考虑 Dart 侧实现。
- **范例：播放页水纹背景**（`app/shaders/ripple.frag` +
  `app/lib/widgets/player/ripple_shader.dart` / `ripple_background.dart`）——
  单 pass 着色器完成折射/饱和/波峰高光/压暗，封面模糊与饱和在 Dart 侧**预烘焙一次**
  （不每帧全屏模糊），每帧只更新 uniform；**着色器不可用时才回退 CPU 网格自绘**。
  设计/性能预算见 `docs/player-render-optimization.md`。

## 发布与签名

发布产物用**一把密钥（key1）**做 ECDSA P-256 / SHA-256 分离签名（`<asset>.sig1`），
由 CI 在受保护 `release` Environment（人工审批）执行；公钥随发布分发
（`ARCHOERA_PUBKEY.pem`）。私钥**绝不入库/入包**。

### 发布流程
1. 升版本 + **更新 `CHANGELOG.md`**（见下节）。
2. 打 tag（`v*`）→ CI 构建三端产物。
3. `release` 作业进入 **Environment 审批**：人工批准后，CI 用 key1 对全部资产签 `.sig1`，
   复制公钥，按 tag 从 `CHANGELOG.md` 抽取说明创建/更新 GitHub Release。

### 更新日志（CHANGELOG.md）
- 根目录 `CHANGELOG.md` 是各版本 **GitHub Release 说明的唯一来源**：release 作业按 tag
  抽取对应 `## [<version>]` 段落作为 Release 正文（见 `.github/workflows/build-all.yml`）。
- **文风**：新增条目须**沿用当前作者的风格**（口语化、「喵」、编号列表等），
  不要改成正式 Keep-a-Changelog 腔调。
- **每次发版必须更新**：在 `CHANGELOG.md` 顶部加一段
  `## [<version>] - <YYYY-MM-DD>`（与 `pubspec.yaml` 的 `version:`、git tag 一致）。
  缺段落时 Release 回退到通用文案。

### 验签（任何人）
```bash
bash app/tool/verify_release.sh /tmp/rel
# 或逐文件：
openssl dgst -sha256 -verify app/tool/watermark_pub.pem -signature x.sig1 x
```

### 密钥生成 / 轮换
```bash
# key1（同时用于二进制内水印，常量写入 app/lib/app/watermark.dart）
bash app/tool/sign_watermark.sh          # 本地运行；CI 环境会拒绝执行
```
轮换后需同步更新：`watermark.dart` 常量、`watermark_pub.pem`、CI 的 Environment secret。
旧发布保留旧公钥以便历史验签。

### 私钥材料（切勿提交/打印）
- key1：`~/.config/archoera/watermark_ec_priv.pem`
- CI secret（**Environment `release`**，非仓库级）：`ARCHOERA_WM_KEY1_PEM`（key1 PEM）。

## 仓库保护（已在 GitHub 配置）
- **Environment `release`**：Required reviewers = 维护者；部署仅允许 tag `v*`；
  含 Environment secret `ARCHOERA_WM_KEY1_PEM`（key1 PEM）。
- **Ruleset `protect-main`**（branch）：要求 PR、禁止强推（non_fast_forward）、禁止删除；
  Required approvals = 0（单人可自建 PR 自合并）。**禁止直接 push `main`**。
- **Ruleset `protect-release-tags`**（tag `v*`）：禁止**更新/删除**已发布 tag（不可移动）。
  故打 tag 前务必确认版本号。
- **CODEOWNERS**：`.github/CODEOWNERS` 把 CI/工具/打包/水印等关键路径指向维护者。

## 触发一次 Release（端到端）
1. **升版本**：改 `app/pubspec.yaml` 的 `version:`（如 `0.9.15+8`）。
2. **更新 `CHANGELOG.md`**：顶部加 `## [<version>] - <YYYY-MM-DD>` 段，沿用作者文风。
3. **提交**：因 `protect-main` 禁直推，走 PR：`git switch -c chore/release-x` →
   commit → push → `gh pr create` → 自合并（0 approvals 即可）。
4. **打 tag 并推**：`git tag v<version> && git push origin v<version>`
   （`v*` 匹配部署策略；**tag 一旦推送不可删改**）。
5. **审批**：Actions → 该 run 的 release 作业停在 **Waiting for review** → Approve。
   CI 用 key1 签 `<asset>.sig1`、复制公钥、按 tag 抽取 `CHANGELOG.md` 段落作为
   Release 正文 → 官方发布完成。

## 红线
- 禁止提交任何私钥/凭据（`.gitignore` 已忽略 `*.key`、`*_priv.pem`；公钥 `watermark_pub*.pem` 需跟踪）。
- 禁止在 CI 运行 `sign_watermark.sh`（会打印私钥材料；脚本已加 `CI` 环境拒绝）。
- 签名步骤不要开 `set -x`。
- "Hmm"等可能会导致死循环，尽可能不要触及

