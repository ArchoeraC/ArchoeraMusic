# 凭据保险库安全说明

凭据保险库（`app/core/vault`）对登录会话与流媒体服务器密码做本地加密存储。以下说明对**测试构建**与**发布产物边界**作出声明，请勿在生产环境启用任何测试开关。

> **安全漏洞请走私密渠道报告**（[SECURITY.md](../SECURITY.md)），禁止公开 Issue / PR / Discussion 讨论漏洞细节。
> 设计与实施细节见 [credential-vault-plan.md](credential-vault-plan.md)；
> 增强方案的定稿与落地记录见 [vault-enhanced-scheme.md](vault-enhanced-scheme.md)。
> **已知缺口与待修复项**见 [security-review-2026-10-11.md](security-review-2026-10-11.md)（本文档的补强台账）。

## 支持的模式（现状 · 2026-10 重构后）

> 2026-10 的 vault 重构**移除了旧模式**：v1（OS 2-of-2）、v2（口令）、v3（设备密封 / 多封装）。
> 随之删除 `DeviceEntropy.cs` / `Fingerprint.cs`，命令 `init` / `init-password` / `init-device` /
> `switch-mode` / `upgrade-device` / `rebind` / `clear-device-seal` / `set-recovery-password` /
> `clear-recovery-password` **全部移除**。**无迁移路径**：旧 vault 文件启动即报
> 「vault 版本不兼容」，用户只能重置（重新登录）。

支持的模式只有以下两类容器：

| 模式 | 代号 | 因子 | 说明 |
|---|---|---|---|
| **crypto（默认）** | `'C'` | 单因子 | 主密钥 K 整体存 **OS 安全存储**（Windows DPAPI / macOS Keychain / Linux libsecret）或 **`file` 后端**（`secret.key`，headless/Docker）；vault 文件不含密钥材料（`key_vault` 为零占位）。OS store 的键**按数据目录作用域**（`SecretKeyScope`，含 `dataDir`），修复旧版「跨数据目录 init 互相覆盖份额」的根因。 |
| **slots（`'S'` 容器）** | `'S'` | m1 / m2a / m2b | 头部槽位表以 KEK 封装 K，条目以 K 加密，尾部 `HMAC-SHA256(K, header‖entries)` 锚定（verify-before-decrypt）。因子模式由槽位集合推导，不写文件头。 |

`'S'`（slots）容器的三种因子模式：

| 因子模式 | 槽位 | 解锁因子 | 级别 / 定位 |
|---|---|---|---|
| **m1** | 口令槽 `kind=1` | 口令（Argon2id），自包含、无 OS 钥匙串 | **口令级**；口令遗忘即重置重建 |
| **m2a** | 口令+设备槽 `kind=4` + 恢复槽 `kind=3` | 口令 + 本地 `device.key`；`device.key` 丢失时用**一次性高熵 Crockford-Base32 恢复码**兜底 | **口令+本机级（最强）**；**推荐** |
| **m2b** | 设备槽 `kind=2` | 仅 `device.key`（本机免密，无口令） | **本机级（较弱）**；单因子，**不建议**用于高价值凭据 |

> **级别与建议（如实声明）**：m2b **无口令、无恢复**，安全级别仅等于本地 `device.key`（`0600`，
> 但**同用户可读**）的存储强度——**读到 `device.key` + vault 文件即可离线解出全部条目**（已实测确认，
> 单因子）。它相对 **crypto**（桌面端走 OS 安全存储 DPAPI/Keychain/libsecret）与 **m2a**（口令 + 设备）
> **基本冗余且明显更弱**。项目**保留** m2b 为**受支持的弱选项**（不删除入口），但**推荐 `m1` / `m2a`**；
> UI 应明确标注「本机级（较弱）」，高价值凭据请勿使用 m2b。

KEK 派生（[SlotCrypto]）：

- 口令槽：`Argon2id(口令, salt, ad = vaultId‖kind)`；
- 设备槽：`HKDF-SHA256(deviceSecret, salt, "archoera.slot.device")`；
- 恢复槽：`HKDF-SHA256(recoveryCodeBytes, salt, "archoera.slot.recovery")`；
- 口令+设备槽：`HKDF-SHA256(Argon2id(口令) ‖ deviceSecret, salt, "archoera.slot.pwdev")`。

**`'S'` 容器布局**：

```
magic "AVLT" | 'S' | vaultId(16B) | createdAt(i64) | alg(1B)
             | slot 表（kind / m,t,p / salt(16) / nonce(12) / wrapped-K(ct‖tag)）
             | entry_count | entries…
             | trailer = HMAC-SHA256(K, header‖entries)
```

KDF 参数有**上限与下限**（[VaultLimits.ValidateKdf]：`m∈[8192 KiB, 256 MiB]`、`t∈[1,16]`、`p∈[1,8]`）——低于下限防「替换成极弱 KDF 槽」降级，高于上限防解锁前内存/CPU DoS。原子写（tmp → fsync → 替换）并保留一版 `.bak`；`Destroy` 删除 vault 文件 + `.bak` + `device.key` + 份额/锁定状态（**`.bak` 与 `device.key` 必须一并删，否则重置后残留可解副本**）。

### Argon2id 强度（用户可选 · init 参数 / `set-kdf`）

- **可选强度**：`init-m1` / `init-m2a` 接受 `--kdf-m <KiB> --kdf-t <迭代> --kdf-p <并行度>` 指定口令承载槽的 Argon2id 参数（均为非密文、可走 argv；缺省用默认档 `m=64 MiB / t=3 / p=1`）。`status` 对 **m1 / m2a** 以 `"kdf":{"m":…,"t":…,"p":…}` 回显当前档位（仅读文件头，不解密任何凭据）；crypto / m2b 无口令 KDF 槽，省略该字段。
- **`set-kdf`（无数据损失重封装）**：`archoera-vault set-kdf <dataDir> [--kdf-m … --kdf-t … --kdf-p …]` 以**当前口令**（stdin 第一行）解锁口令承载槽，**保持主密钥 K 与全部条目不变**，仅以新参数、新 salt/nonce 重新封装该槽并重算尾部 HMAC（原子写 + `.bak`）。口令错误 / 槽被篡改 → AES-GCM 认证失败（fail-closed，不改动任何字节）。**m2a** 另需本地 `device.key`（缺失时转恢复码流，恢复槽原样保留）；**crypto / file / m2b 无口令 KDF 槽，不支持**（明确拒绝）。
- **合法区间**（[VaultLimits.ValidateKdf]；`--kdf-*` 与 `set-kdf` 均经此校验）：`m∈[8192 KiB(8 MiB), 256 MiB]`、`t∈[1,16]`、`p∈[1,8]`，越界在派生前快速拒绝。
- **应用拟暴露的预设**：低 = `32 MiB / t=3`；中（默认）= `64 MiB / t=3`；高 = `256 MiB / t=4`（均在上界内）。应用侧以设置项呈现。
- **权衡**：档位越高 = 离线暴破成本越高，但**解锁越慢、单次解锁占用内存越多**（高档在低内存设备上可能压力较大）；调高只增加攻击成本，不改变因子结构。

### 在线退避 ≠ 抗离线暴破（如实声明）

- **在线退避是 best-effort，不是安全边界**：连续解锁失败按 `1s → 2s → … → 5min 封顶`指数退避，锁定期间 `serve` 握手直接拒绝（连尝试都不做）。slots 模式的退避状态落明文 `<dataDir>/vault.lockout`（**同用户可删 / 可改**）；crypto 模式内嵌于 `master-share` 份额。
- **删状态即可清零退避**：能删除状态文件的同用户攻击者可绕过它；且 **离线暴破根本不经过 vault 进程**——攻击者拿到 vault 文件后可自行离线跑口令猜测，在线退避对其**无效**。
- **真正的抗暴破杠杆只有两个**：**KDF 成本**（Argon2id 参数强度，见上）与**口令 / 恢复码熵**。请据此设定强度与口令策略，**勿把退避当作保密防线**。

## 三端：Rust 实现（2026-10）

自 2026-10 起，**三端发行包**内的 `native/archoera-vault[.exe]` 统一改为
`app/core/vault-rs` 的 **Rust 实现**（取代 C# NativeAOT；`app/core/vault/**` 已于 2026-10-12
**删除**，字节兼容由 `testdata/` 黄金夹具锚定）：

- **Linux**：**静态链接**单文件（`+crt-static`；CI 走 musl 静态）分发。
  **免疫加载器注入**：静态二进制不依赖 `ld.so`，`LD_PRELOAD` / `LD_AUDIT` /
  `LD_LIBRARY_PATH` 对其**完全失效**——这是 [vault-enhanced-scheme.md §13-A](vault-enhanced-scheme.md)
  「LD_PRELOAD 曾经完全失守」的**根治**；C# NativeAOT 因链接器限制无法静态化（§13-E）。
  Linux 上 crypto 模式走 **`file` 后端**（`secret.key`，0600；单因子降级，选用须知悉），
  slots（m1/m2a/m2b）本就自包含、不依赖 OS store；**不使用 libsecret**（Rust 侧
  libsecret 仍为桩）。
- **Windows**：crypto 模式走 **DPAPI**（`CryptProtectData` / `CryptUnprotectData`，
  `CRYPTPROTECT_UI_FORBIDDEN`，密文落 `<dataDir>/sshare.bin`，后端指纹 `dpapi`）；
  以 `cargo build --release --target x86_64-pc-windows-msvc -C target-feature=+crt-static`
  构建（自包含 CRT）。
- **macOS**：crypto 模式走 **Keychain**（`kSecClassGenericPassword`，service
  `archoera.vault`，account 按数据目录作用域 `{key}|{dataDir}`，原始字节值）；
  `aarch64-apple-darwin` + `x86_64-apple-darwin` 双架构经 `lipo` 合成 universal。
- **字节 / 协议兼容**：容器格式（crypto `'C'` / slots `'S'`）与 KDF/HKDF/AEAD 语义由
  `app/core/vault-rs/testdata/` 的**冻结黄金夹具**锚定（`test.sh` §14 / `test-windows.sh` §11 读回固定值）；
  C# 活体 oracle（旧 `cross_parity.sh` 双向互解互读）已于 2026-10-12 随 `app/core/vault/` 一并删除。
- **构建 / 打包**：Linux `app/core/build-linux.sh`；Windows `app/core/build_windows.bat`
  （install 见 `app/windows/CMakeLists.txt`）；macOS `app/core/build-macos.sh` +
  `app/macos/Runner.xcodeproj` 拷贝阶段；CI macOS bundle 从 `core/vault-rs/build/` 取。
  SEC-08 完整性清单仍自动覆盖该文件。
- **真机 / Wine 验证现状**：Windows 侧**已在 Wine 上端到端实测**（`app/core/vault-rs/test-windows.sh`：
  DPAPI 读写 `sshare.bin`、打包布局血缘校验（`NtQueryInformationProcess` +
  `QueryFullProcessImageNameW` + 大小写不敏感比较）、握手 10s / 空闲 30s / `set` 负载 30s
  超时、畸形与超长输入、并发多会话、destroy 全量清理、退避状态篡改，以及「Windows 写 →
  Linux Rust 读」跨 OS 互通 + Windows 读 Linux 黄金夹具）；会话超时与空闲自退均以**内核阻塞等待**
  实现（读线程阻塞读 + 单一截止时刻/事件唤醒，空闲实测 0.00% 单核），**不引入轮询**——
  避免把「轮询」本身变成 CPU 空转型攻击面或可观测节拍；macOS 侧**仅完成 Linux 交叉编译与链接
  检查**（`app/core/vault-rs/cross-macos.sh`：双架构 + `lipo` + `minos`/框架断言），
  Keychain 读写、`proc_pidpath` 父进程校验、`DYLD_INSERT_LIBRARIES` 拒绝、`RLIMIT_CORE`
  等**运行期行为仍待 macOS 真机**；Windows `SetProcessMitigationPolicy`（ACG/CIG 等）为
  best-effort，Wine 下无法观测生效情况，亦待真机。CI 覆盖三端**原生编译**与纯函数单测，
  Linux 端到端实测全绿。
- **Wine 环境注意**：经 Unix 侧 `wine <vault>.exe` 直启时 Wine 不回填
  `InheritedFromUniqueProcessId`（实测恒 0），血缘校验按「父进程缺失」拒绝运行；
  故 Wine 侧测试一律经 `wine cmd /c`（或其它 Windows 侧父进程）启动。C# 版同源逻辑
  在 Wine 下行为相同，属加载器行为而非实现缺陷。

## 测试构建（无明文后门，SEC-19 已删除）

- **Linux（Rust）**：`app/core/vault-rs/build-test.sh`（`vault_testing` feature 条件编译）
  产出 `archoera-vault-test`，同样**仅改构建标记、存储行为与生产一致**；套件为
  `app/core/vault-rs/test.sh`（含内存护栏、安全落盘、沙箱完整性、黄金夹具四类回归）。
- **Windows（Rust，Wine 交叉验证）**：`app/core/vault-rs/test-windows.sh` 用
  msvc-wine + LLVM `lld-link` 交叉构建 `x86_64-pc-windows-msvc`（`+crt-static`，导入表
  只有系统 DLL，无 MSVC 运行时分发依赖）后在 Wine 上跑真实 Windows 产物；含打包布局
  血缘探针与会话超时探针。缺 wine / MSVC 布局时打印原因并跳过（可选验证）。
- **macOS（Rust，交叉编译检查）**：`app/core/vault-rs/cross-macos.sh` 在 Linux 上用
  macOS SDK + `clang --target=…-apple-darwin` + `ld64.lld` 双架构构建、`llvm-lipo` 合包，
  并断言 `minos` 与 `Security.framework` 链接；**仅编译期覆盖，运行期须真机**。
- 历史上存在测试专用明文存储开关 `ARCHOERA_VAULT_INSECURE_FILE_STORE`（C# `InsecureFileStore`）——
  **已于 SEC-19（2026-10-12）删除**。`test.sh` 与 CI 的 headless 后端改用**生产 `FileStore`**
  （`ARCHOERA_VAULT_BACKEND=file`，文件密钥模式），不再有任何明文存储代码路径；`VAULT_TESTING`
  仅保留用于构建标记。
- 测试产物 `archoera-vault-test` **绝不进入发布产物**（bundle / 安装包 / release artifact 均不含，打包流程无引用）。

## 构建标记校验（防「误用测试 / 构建」混入）

> **定性**：本节机制只是**构建自报指纹校验**，用于防止**误用测试构建**，**不是**「二进制替换防护」——marker 是可自报的字符串（无签名 / 无认证），攻击者可自行编译输出 `ARCHOERA-VAULT-PROD-*` 的后门 vault 通过校验。
> 真正的应用层二进制完整性由 **key1 签名的原生完整性清单**承接（见下节 F5，SEC-08）；无 OS 代码签名 / 硬件根时仍无法防「替换主程序」。

- **双重校验（fail-closed）**：
  1. **加载前校验**：`archoera-vault --version` 输出 `ARCHOERA-VAULT-PROD-*` 才允许解析默认路径二进制；
  2. **握手内 marker 校验**：每次 serve 会话的握手应答尾部携带构建标记 `BuildInfo.Marker`（PROD/TEST 版本指纹）。主程序解析应答第 5 字段——默认路径解析的 vault 必须为 PROD 标记，**缺失或非 PROD（TEST 构建 / 被替换的官方测试产物）→ 杀进程 + 删除默认路径副本 + 拒绝解密 + 置版本异常 fatal 态**，UI 顶层 `VaultVersionGate` 全屏拦截，**仅允许用户退出**；
- 该机制可拦截**被替换为官方测试构建**（TEST 标记）的情形；攻击者**自行编译**一个照旧输出 PROD marker 的后门二进制时，本机制**无法识别**（见上方定性）；
- `ARCHOERA_VAULT_BIN` 仅作为显式信任边界供测试/CI 使用（设置进程环境本身即需系统权限，生产路径绝不设置）：env 显式指定的二进制跳过 PROD 校验（信任边界），但 marker 存在性仍校验，且 **SEC-08 清单校验仍适用**（清单锚定可执行文件本身，不因 env 指定而被劫持）。

## 父进程身份校验（F3 · 无环境变量信任）

- 旧版的 `ARCHOERA_VAULT_PARENT_OK` 环境变量**已完全移除**——血缘校验不再读取任何环境变量作为信任来源。
- 现状：vault 校验由 **OS 提供**的父进程 pid + 父进程可执行文件路径，与「**由 vault 自身位置推导出的预期主程序路径**」比对：
  - 父进程 pid 由 OS 取得（Linux/macOS `getppid`；Windows `NtQueryInformationProcess`）；
  - 父进程可执行文件路径由 OS 读取（Linux `/proc/<ppid>/exe`、macOS `proc_pidpath`、Windows `QueryFullProcessImageNameW`）；
  - **Rust（`app/core/vault-rs`）实现**：Linux `read_link("/proc/<ppid>/exe")`；macOS `proc_pidpath`（libproc 经 `dlopen`/`dlsym` 解析，优先逻辑名 `libproc.dylib`、回退 `/usr/lib/libproc.dylib`，与 C# 一致）；Windows `NtQueryInformationProcess`（父 pid）+ `OpenProcess`/`QueryFullProcessImageNameW`（父进程映像），路径比较**忽略大小写**。**Windows 运行期路径已在 Wine 上实测**（打包布局放行 / 非预期拒绝 / 大小写不敏感；`test-windows.sh`，唯 Wine 直启不回填父 pid 见同节注意）；**macOS 运行期仍待真机**。
  - 仅**打包布局**（vault 位于 `<dir>/native/<vault>`，预期主程序为 `<dir>/archoera_music[.exe]`）作路径绑定；dev/测试布局（目录名非 `native`）与预期主程序缺失时**放行**（仅记日志，避免自砖）。
- **残余（如实）**：同用户攻击者若在**预期主程序路径放一个自造二进制**再 spawn vault，本校验无法与「主程序被替换」区分——这正是威胁模型声明的硬上限（见下节），属 L4 信任根范畴。

## 进程自我保护（F4 · best-effort）

vault 进程**入口即硬化**（`main` 调 `guard::harden_process()`，**覆盖所有命令**，
不只 `serve`——一次性命令 `init-*` / `set-kdf` / `destroy` / `status` 同样在内存里持有口令与主密钥，
`init-m2a` 还会打印恢复码）：自施 OS 提供的防注入 / 防转储缓解（浏览器同款做法，**不依赖启发式注入检测、不做反调试伪装**）；三端均为 `app/core/vault-rs` 的 Rust 实现（Windows 的 `SetProcessMitigationPolicy` best-effort 降级仍待真机观测；macOS 运行期待真机）：

- **内存护栏（Rust 三端，[`app/core/vault-rs/src/memguard.rs`](../app/core/vault-rs/src/memguard.rs)）**：
  主密钥 / KEK / 单条明文（`get` 结果、`set` 负载、握手口令）一律进 **`LockedBuffer`** ——
  Linux/Unix `mlock`、Windows `VirtualLock`、Linux 另加 `madvise(MADV_DONTDUMP)`，drop 时**先 zeroize 再解锁**；
  启动时尽力抬高额限（`RLIMIT_MEMLOCK` 软限→硬限 / Windows 工作集下界），仍失败则**如实告警并降级为「仅 zeroize」**
  （可用 `archoera-vault selftest-mem` 查询 `locked=true|false`）。**每缓冲独占页**（页对齐分配）——
  否则相邻小缓冲的 `munlock` 会把仍在使用的缓冲一并解锁（实测会话期 `VmLck` 归零）。
  配套：`get`/`set` 明文与响应串、会话主密钥、读线程行缓冲均 `Zeroizing`/`LockedBuffer` 收口；
  stdout/stdin 走**原始句柄 + 自有可零化缓冲**（`std::io::{stdin,stdout}` 的全局缓冲会把明文留在堆上）。
- **Linux**：`prctl(PR_SET_PDEATHSIG, SIGTERM)`（父死自动退出）、`RLIMIT_CORE=0`（崩溃不产 core）、`PR_SET_DUMPABLE=0`（禁 `/proc/pid/mem`、ptrace 读取），以及 **seccomp-BPF denylist 过滤器**：命中 `ptrace` / `process_vm_readv|writev` / `execve` / `bpf` / 内核模块 / 命名空间 / `io_uring` 等，以及 **`AF_INET` / `AF_INET6` 的 `socket()`** → `SECCOMP_RET_KILL_PROCESS`（内核以 `SIGSYS` 杀进程）。**`AF_UNIX` 一律放行**，故 libsecret / D-Bus 仍可用；`clone`/`clone3` 等线程创建路径有意放行（避免删 NativeAOT 运行时而自砖）。
- **denylist 逐条生效性自检**（Linux）：`archoera-vault selftest-seccomp list` 对每条被拒系统调用各 fork 一个
  子进程**实际调用一次**，内核以 `SIGSYS` 终止才算生效（过滤器「装载」≠ 名单真的拦得住）；实测 `killed=33/33`。
- **Windows**：`SetProcessMitigationPolicy` —— ACG（禁动态码）、CIG（仅可信镜像）、ExtensionPointDisable、StrictHandle、CFG、ImageLoad 约束，**全部 best-effort**（旧系统/与运行时冲突时失败即忽略，不阻断启动）。
- **macOS**：仅 `RLIMIT_CORE=0`。macOS 无 seccomp 等价物（完整沙箱需 entitlement / 沙箱描述文件，本仓库不引入）；`ptrace(PT_DENY_ATTACH)` 已废弃且属反调试，明确不用。
- **边界（重要）**：
  - 全部 **best-effort、fail-open**：内核不支持 / 受限容器 / `SetProcessMitigationPolicy` 失败时静默降级，**绝不令 vault 启动失败**；
  - 触发被拒系统调用 / ACG 时的 OS 终止（`SIGSYS` / `STATUS_DYNAMIC_CODE_BLOCKED`）经既有**崩溃标记**路径暴露，下次启动由 `VaultCrashGate` 提示；**没有实时 UI 告警**（vault 被 OS 杀 → 主进程 fail-closed 随之退出，进程已不存在）；
  - **任何情况下都不删除用户数据**（自毁 = 进程终止 + 会话态清零，**≠ 数据销毁**）；
  - 这只是**进程自我保护**，不构成对「主程序被攻陷 / 同用户替换主程序」的防线。

## 应用层信任根：key1 签名的原生完整性清单（F5 · 取代 OS 代码签名承诺）

- **原生完整性清单 `ARCHOERA-NATIVE-MANIFEST.txt`**（构建期对 `native/` 全部文件生成 SHA-256）现由 **key1 签名**为 `ARCHOERA-NATIVE-MANIFEST.sig1`（ECDSA P-256 / SHA-256）；
- 运行期 `NativeIntegrity` 用**二进制内嵌公钥**（`app/lib/app/watermark.dart`）**先验签、再比对摘要**：签名存在但不合法 → **fail-closed**（抛错、拒绝加载该库）；无签名（仅摘要）回退为 hash-only 并提示一次（过渡兼容）；开发态 / 无清单跳过并警告（保证 `flutter run` 与测试可用）；
- **vault 二进制在 spawn 前**亦经该清单校验（`VaultProcess._resolveBinary`），不再依靠可伪造的 `PROD-*` marker 作主防线（marker 退回「防误用测试构建」的原用途）；
- **CI 覆盖面**：`release` 作业对**可被 release 控制的目录型产物**签名清单——macOS / Windows tar、Linux 原始 bundle、Windows 便携 zip；
  **deb / rpm / AppImage / flatpak / pkg.tar.zst / nixos** 依赖**各发行版包管理器签名**、Inno `.exe` 依赖**外层 `.sig1`**，**不在此重签**；
- **硬上限（如实）**：验证逻辑本身运行在**可被替换的进程**里，且 `ARCHOERA_VAULT_BIN` 显式指定时清单若缺失（dev）会跳过——**替换主程序 / 同用户运行期注入主程序不可防**，需要 OS 代码签名或硬件根（TPM / Secure Enclave）。
  **OS 代码签名当前不推进**（Windows Authenticode / macOS 公证因成本与步骤不可得，见 [supply-chain.md §2](supply-chain.md)）——因此**应用层 key1 签名清单是当前的真实性机制**：用户可用分发公钥**离线**核验 `.sig1` 与清单。

## 信任根边界（威胁模型声明）

- **应用层防线覆盖范围**：爆破主密钥（→ 强 KDF + 退避锁定 + 高熵因子）已纵深防护；**替换 vault 二进制**由 key1 签名清单覆盖（攻击者无 key1 不能同时改文件与清单），构建标记仅再兜「原样换成官方 TEST 产物 / 缺 marker」；
- **同用户攻击者不在防线内**：父进程身份校验只保证「它确实是预期主程序 / 直接父进程」，无法保证「主程序未被篡改」；同用户攻击者可自行 spawn vault 并自选会话密钥 `H/C`——血缘 / 握手只防「无主进程上下文的误用与自动化」，**不防同用户进程**；
- **边界**：信任根在主程序进程。攻击者**同时替换主程序（Dart 可执行 / FFI 库）** 或**在其内嵌主动联网上传程序段**时，vault 视主进程为合法握手对象、无法区分被篡改的主程序——此威胁（进程注入 / 信任根攻破）**超出应用层能力**；**OS 代码签名不推进**（见 [supply-chain.md §2](supply-chain.md) / [security-review SEC-25](security-review-2026-10-11.md)），故该缺口**如实保留**，仅靠应用层 key1 清单无法完全封堵；
- 本方案无法承诺具有拦截「同用户权限下完全控制进程 / 按源码重实现的攻击者」的能力（Kerckhoffs 原则，见 [credential-vault-plan §1.2](credential-vault-plan.md)）。

## 凭据存储与恢复

- **crypto 模式**：K 存 OS 安全存储 / `file` 后端；OS store 键按数据目录作用域（含 `dataDir`），避免跨目录覆盖。`file` 后端为**单因子**（`secret.key` 0600），密钥文件泄露 = 凭据全泄露，选用即显式接受该降级（headless / Docker 场景）。
- **slots 模式**：
  - m1：口令遗忘 = 数据不可解 → 重置重建（重新登录）；
  - m2a：`device.key` 丢失可用**恢复码**解锁（恢复码仅初始化时输出一次，须妥善保存；**当前不提供「重新生成恢复码」命令**）；口令与恢复码皆丢失 → 重置重建；
  - m2b：仅本机 `device.key`，无口令无恢复——`device.key` 丢失即重置重建；**级别为本机级（较弱）**，`device.key`（同用户可读）泄露即等于凭据全泄露。
- **恢复 / 重置**：执行 `archoera-vault destroy <数据目录>`（或设置页「清除所有本地凭据」）会一并删除 vault 文件、`.bak`、`device.key` 与份额/锁定状态；**旧密文不可恢复，需重新登录各平台账号**。
- **销毁语义（不自毁，实测）**：**任何攻击/失败路径都不删除用户数据**——沙箱被违反（SIGSYS）、被 `SIGKILL`/`SIGSEGV`
  打爆、vault/`device.key`/`secret.key` 被篡改或截断、加载器注入被拒、重复 `init-*` 回滚，**都只 fail-closed 拒绝服务**
  （文件保持原样、复原后即可解锁；崩溃也不产 core）。唯一的数据销毁入口是**显式** `destroy`（或设置面板按钮）；
  应用层非预期退出只写 `crash` 标记并 `exit(86)` 终止主进程，版本异常只删除**二进制副本**，均不触碰凭据。
- **数据目录**：Linux `~/.local/share/ArchoeraMusic`；macOS/Windows 见应用数据目录（路径解析见 `resolveDataDir()`）。

## 环境变量与信任边界（完整清单）

> 本节完整声明所有影响安全面的 `ARCHOERA_VAULT_*` 环境变量及其信任边界（SEC-14）。**生产路径不得设置任何变量**（旧版的 `ARCHOERA_VAULT_PARENT_OK` 已完全移除，不再由主进程自动注入）。

| 环境变量 | 作用 | 信任边界 / 影响 | 生产 |
|---|---|---|---|
| `ARCHOERA_VAULT_BIN` | 显式指定 vault 二进制路径 | 显式信任边界：**跳过默认路径的 PROD marker 校验**（marker 存在性仍校验）；SEC-08 清单校验仍适用。能设置进程环境即属调用方权限 | ❌ 不设置 |
| `ARCHOERA_VAULT_BACKEND=file` | 选择文件密钥后端（`secret.key`，0600；`ShareBundle` 容器）。**测试/CI 用它作 headless 后端**（SEC-19 后无明文后门） | **弱化**等级：单文件密钥泄露即凭据全泄露，弱于 OS 存储；已记录非 `file` 后端的 OS/crypto 库不被覆盖 | ❌ 不设置 |
| `ARCHOERA_VAULT_SECRET_KEY` | ~~覆盖主密钥 K~~ | **已移除**（SEC-02）：改为 `init-file --key-stdin`（stdin 首行 hex64，不经 argv/env）；env 会出现在 `/proc/<pid>/environ`（同用户可读），故不再支持 | ⛔ 已移除 |
| `ARCHOERA_VAULT_FINGERPRINT` | ~~覆盖设备指纹来源~~ | **已移除**：v3 设备绑定 / `Fingerprint.cs` / `DeviceEntropy.cs` 已随 2026-10 重构删除，无设备指纹采集 | ⛔ 已移除 |
| `ARCHOERA_VAULT_PARENT_OK` | ~~血缘白名单~~ | **已完全移除**（F3）：父进程身份改由 OS 提供（pid + 可执行文件路径）校验，不读任何 env | ⛔ 已移除 |
| `ARCHOERA_VAULT_INSECURE_FILE_STORE` | ~~测试明文存储开关~~ | **已删除**（SEC-19）：`InsecureFileStore` 移除，测试用生产 `FileStore` | ⛔ 已移除 |
| `ARCHOERA_VAULT_NO_ABORT=1` | 崩溃联动测试豁免（仅写 `vault.marker`，不 `exit(86)`） | 测试专用；设置后崩溃不在主进程侧 fail-closed | ❌ 不设置 |

## 已知安全边界与缺口（如实声明）

以下为**文档层评审已登记**的边界 / 缺口，本文档如实声明，**勿视为已防护项**（其中 SEC-04 / SEC-07 的**表述定性已修正**，SEC-01 已纳入 vault，SEC-06 已加固，SEC-19 后门已删除）。完整台账（含证据、影响、修复方向、状态与批次）见
[security-review-2026-10-11.md](security-review-2026-10-11.md)：

- **Subsonic 用户密码已纳入 vault**（SEC-01，**已修复**）：用户密码不再以 `database/user.db` 的 `enc:v1:` 字段级加密 +
  `dataDir/secret.key` 自举为唯一保护，而是经 vault 统一持久化（uid=`subsonic:<username>`，Dart `VaultSubsonicCredentialStore`）；
  `password_cipher` 仅空串占位，服务端认证经 `archoera_subsonic_set_credentials` 注入内存凭据表。
  旧库 `enc:v1:` 密码在 `SubsonicAdmin.open` 时解密迁入 vault（成功才置空该列，失败保留待重试）。
  注：`secret.key` 与 vault `file` 后端密钥文件同名且为同一文件，现仅服务 vault file 模式；Subsonic 凭据不再依赖它（2026-10-12 修复）；
- **file 模式与主密钥 env**（SEC-02）：file 为单因子（K 落盘 `secret.key`，`ShareBundle` 容器），选用即显式降级；
  原 `ARCHOERA_VAULT_SECRET_KEY` **env 注入已移除**，改为 `init-file --key-stdin`（不经 argv/env）——
  与 [credential-vault-plan.md](credential-vault-plan.md) §3.8「argv / 环境不携带任何凭据」一致；
- **启动预取明文驻留**（SEC-03，**已收敛**）：`StreamingStore.preloadSecrets()` **不再**逐服务器解密——
  仅做 vault 惰性初始化与模式探测；凭据由 `StreamingStore.loadSecret(id)` 在真正需要时**按需单条解密**，
  且**不写回长驻 UI 状态**（`StreamingState` 只保留非敏感元数据；带凭据配置仅临时构造给客户端）。
  残余：Dart `String` 不可 zeroize、不受 mlock 保护，被解密的那一条明文在一次会话内仍会短暂存在于堆中；
  缓解为主进程 `PR_SET_DUMPABLE=0` + `RLIMIT_CORE=0`（**该句原为对 vault 子进程的估低**：实测 `PR_SET_DUMPABLE=0`
  下同用户对 vault 的 `ptrace`/`process_vm_readv` 返回 `EPERM`、`/proc/<pid>/{mem,maps,smaps,environ}` 返回 `EACCES`，
  即对 vault 进程是覆盖的；仅 Dart 主进程自身不设该标志）；
- **PROD marker 定性过高**（SEC-04）：marker 为可伪造字符串，只能防「误用测试构建」，**不能防替换二进制本身**；
  应用层二进制完整性改由 **key1 签名清单（F5/SEC-08）** 承接；
- **敏感文件读写规则**（SEC-37/38/44/45，`app/core/vault-rs/src/safefile.rs`）：`credentials.vault`、`.bak`、
  `secret.key`、`device.key`、`sshare.bin`、`vault.lockout` 统一走安全原语 ——
  **写**：`<path>.tmp.<pid>`（**进程唯一**，避免多会话并发保存互删对方 tmp）以 `O_CREAT|O_EXCL` 独占创建，
  已存在的 tmp **仅当是普通文件**（崩溃残留）才清理重建，符号链接 / FIFO / 设备一律拒绝；`.bak` 改**原子写**
  （旧实现 `fs::copy` 会跟随目标符号链接写到任意文件）；**容量上限在写入前校验**（单条 ≤ 4 MiB−16B、
  整库 ≤ 16 MiB，否则拒绝且不动磁盘——否则会写出「下次加载即被拒」的自锁库）；
  **读**：`read_regular_limited` —— 拒绝符号链接 / FIFO / 目录，且**读之前**按元数据判长度
  （植入 FIFO 会阻塞、植入超大文件会 OOM）；退避状态读取异常一律视为「无锁定」（best-effort，绝不成为可用性攻击面）。
  残余（如实）：同用户仍可**删除**这些文件（DoS / 退避重置）；这属已声明的同用户边界。
- **并发语义（兼容并发，SEC-46）**：写命令（`set`/`delete`/锚点/`set-kdf`/`init`/`destroy`）以**阻塞式跨进程独占锁**
  保护「加载 → 改 → 保存」——`flock(LOCK_EX)` / `LockFileEx`，内核事件唤醒（**非轮询**），
  **崩溃自动释放**（无陈旧锁），锁范围=单条命令（多会话仍可交错）。锁文件 `<dataDir>/vault.lock`
  内容为空、非敏感面、**永不删除**（删除会让持锁进程与新进程各锁不同 inode、互斥失效）。
  此前为「最后写者获胜」= 静默丢更新（并发 `set` 互相覆盖、或把重键头部写回），不可接受。
  注：握手路径的「取/建锚点」也取一次锁，故外部长期持锁会连带阻塞握手（由调用方超时约束）。
- **应用层（Dart）文件访问统一收口**（SEC-47，`app/lib/utils/safe_file.dart`）：**全部**配置/状态文件
  （`prefs.json`、`scan_dirs.json`、`streaming_servers.json`、`netease_session.json`、`last_session.json`、
  `daily_shelf.json`、`download_history.json`、封面、`vault.auth` 锚点、`vault.marker` 标记、SEC-08 清单/签名/
  被校验库、缓存分片）改走 `SafeFile` —— **读**要求「必须是普通文件」（`allowSymlink` 默认 true 以兼容
  把配置软链到 dotfiles 的用户；锚点/签名/标记用 false）+ 长度上限；**写**走「同目录随机唯一临时名 → `rename`」，
  符号链接**只被替换、不被穿透**。擦除器（`data_destroyer`）只擦**普通文件**，且不再把非普通路径交给
  Go 代理（其覆盖写会顺链抹掉目标）。→ 此前「植入 FIFO 即冻结界面 / 顺链覆盖任意文件」的**确定性**攻击面消除。
  **残余（如实）**：`dart:io` 无 `O_NONBLOCK`/`O_NOFOLLOW`，类型判定与真正读写之间存在极窄 TOCTOU 窗口
  （需精确抢时）；彻底关闭需经 `app/native/platform` 走原生 `open(2)`，当前未做。
- **Windows 内存读取面**（SEC-39，**应用层不可封闭**）：Windows 无「禁同用户读进程内存」的等价物
  （ACG/CIG/StrictHandle 均不拦 `OpenProcess(PROCESS_VM_READ)` + `ReadProcessMemory`），故同用户进程可在会话期
  读走主密钥与刚流经的凭据（`mlock`/`VirtualLock` 只防换页、不防读）。配套：DPAPI 份额**不带 `pOptionalEntropy`**
  → 保护只绑定 OS 用户，**同用户任意进程**可解封出主密钥（实测：非 vault 二进制解封 + 直解 vault 条目成功）。
  这是「同用户攻击者不在防线内」的具体化；可信边界应视为**用户账户**而非本应用。
  **Wine 注意**：Wine 的 `CryptProtectData` 为固定密钥实现（换 `WINEPREFIX` 仍可解封），**不能**用于验证
  「用户绑定」，该点须真机复验；「同用户可解封」的结论来自 API 语义（无 entropy），与 Wine 无关。
- **lockout / auth / marker 同用户可写**（SEC-05）：`vault.auth` 可随 vault 一并替换（锚点失效）、
  `vault.marker` 可伪造（**注意**：伪造 `crash` 只让下次启动弹可关闭的崩溃警告，**不会**触发 `exit(86)`——
  `exit(86)` 仅由「vault 子进程真实异常退出」路径触发；伪造 `ok` 可掩盖一次真实崩溃的提示）——
  **已如实声明：这些文件不构成对同用户攻击者的防线**。
  退避状态（`vault.lockout`）的**加固思路**：crypto 模式退避状态**内嵌于 `master-share` 份额槽位**
  （`ShareBundle`）——删除/伪造明文 `vault.lockout` 不再重置退避（删份额即砖化单槽后端）；
  **slots 模式**（m1/m2a/m2b）份额由口令 / 设备熵 / 恢复码现场派生、不入库，仍回退明文
  `vault.lockout`，属此类模式的已声明残余风险。
- **KDF 参数加载上限 / 下限**（SEC-06，**已修复**）：头部与槽位块的 Argon2id `m / t / p` 现经
  `VaultLimits.ValidateKdf` 解析校验（`m∈[8192 KiB, 256 MiB] / t∈[1,16] / p∈[1,8]`），越界在派生前快速拒绝（`InvalidDataException`），
  `ReadHeader`（握手前）与 `Load`（解锁）均覆盖，`Argon2id.Derive` 另设同上限纵深防御；头部参数被篡改只会派生错误的 K（槽位 GCM 认证失败 / 尾部 HMAC 失败），不泄露数据；
- **父进程身份不防同用户**（SEC-07，**表述定性已修正**）：血缘校验不读任何 env，由 OS 提供父进程 pid 与可执行文件路径并比对预期主程序路径；但同用户攻击者可在预期路径放置自造二进制再 spawn，**无法与「主程序被替换」区分**；
- **应用层完整性清单的残余**（SEC-08）：key1 签名清单能拦「安装后替换 `native/` 文件」，但**主程序自身未被校验**（进程无法自证），Dart 亦无法拦截原生传递依赖（FFmpeg / 转码器）的 `dlopen`；`ARCHOERA_VAULT_BIN` 显式指定且 dev 无清单时会跳过——这些仍须 OS 代码签名 / 安装包完整性承接。
