# Vault 增强加密方案（已落地 / 定稿）

> 状态：**已落地 / 定稿（2026-10 重构实施）**。取代此前的多槽 v5 提案。
> 结论先行：**砍掉 v1（OS 钥匙串）/ v3（设备熵）/ v4（文件密钥）的分层**，只保留
> **①手动口令模式（m1）** 与 **②增强模式（m2a 双因子 + 恢复码 / m2b 设备单因子）**，另保留 **crypto（默认，OS 存储 / file）**；
> 并如实划清"防爆/防替换/防注入"在**无 OS 代码签名、无硬件安全模块**前提下的**可行边界**。关联：[vault-security-notes.md](vault-security-notes.md) ·
> [credential-vault-plan.md](credential-vault-plan.md) · [security-review-2026-10-11.md](security-review-2026-10-11.md)。
>
> **落地说明**：本文的 §0–§4、§6 已按实施结果修订；§5 的评估项标注了「已落地 / 未采纳」；
> **§8/§9 的部分工程建议（二进制帧 IPC、流式解密、旧 v1–v4 读兼容）实为未落地项**，已就地标注，勿据原文误判。

---

## 0. 结论要点

1. **现有模型的问题**：本质是"常规 AEAD + 自持框架"的自研重写，各模式（v1–v4）级别不清、
   稳定性不足（OS 份额全局覆盖致永久失效、跨存储迁移非原子、设备指纹漂移、headless 不可用）。
2. **收敛**：只需两种模式——**口令模式（便携自含）** 与 **增强模式（本机绑定）**；
   二者共用同一容器格式与同一条加解密路径，降低体积与维护面。
3. **"防替换 / 防注入"没有银弹**：无 OS 签名 / 无 TPM·SecureEnclave 时，**无法阻止同用户运行期
   替换主程序**；能做的只有 (a) **移除可伪造的信任参数**、把进程身份绑定到 OS 级事实
   （✅ 已落地：F3 移除 `ARCHOERA_VAULT_PARENT_OK`，改由 OS 提供 pid + 可执行文件路径），
   (b) 用**应用层 key1 签名清单**检测"仅替换 FFI/vault 文件"（✅ 已落地：F5，`ARCHOERA-NATIVE-MANIFEST.sig1`），
   (c) 把静态数据保护压到 **OS 之外的离线攻击**（强 KDF + 可选设备因子）。**如实声明残余，不夸大**。
4. **防爆**：参数上下限（✅ 已落地：`VaultLimits` 同时设上限与下限，防降级 / 防 DoS）+
   **强度用户可选**（✅ 已落地：`init-m1`/`init-m2a` 的 `--kdf-m/--kdf-t/--kdf-p` + `set-kdf` 无数据损失重封装，见 §12）+ 在线退避
   （✅ crypto 模式状态内嵌 `master-share`；slots 模式回退明文 `vault.lockout`，属残余）。
   **⚠️ 未落地**：Argon2id "按设备自适应校准"未实现（默认档仍 `m=64 MiB / t=3 / p=1`）。
   **离线暴破无法限速**（在线退避只约束交互路径，离线猜测不过 vault 进程），唯一杠杆是 KDF 成本与口令熵。
5. **效率**：AEAD 用硬件加速的 **AES-256-GCM**（✅ 已落地；**未落地**:ChaCha20-Poly1305 回退——当前仅 AES-256-GCM 一种，`alg=1`）；
   单容器最小 header；主进程不缓存口令（✅ SEC-03 已收敛）。
   **⚠️ 未落地**：大库流式解密 / 增量写 —— 当前 `VaultFile.Load` 整文件读入（上限 16 MiB）。

---

## 1. 为什么"推翻重来"

| 现有模式 | 级别 | 主要缺陷 |
|---|---|---|
| v1 OS 钥匙串 | 未明确 | 全局命名空间无 per-app/per-dir 隔离 → 任何副本 `init` 覆盖份额 → **永久失效**；headless 不可用 |
| v2 口令 | 高（口令） | 仅单因子；遗忘即全丢 |
| v3 设备绑定 | 中 | 指纹漂移 → NEED_RECOVERY；熵文件与 vault 同目录被窃 → 降级 |
| v4 文件密钥 | 低 | 单文件泄露即全泄露；文件丢失即全丢 |

共同点：**可解性绑定在单一外部/易变状态**，且"安全级别"从未清晰定义 → 用户无法判断该用哪个。

---

## 2. 目标（收敛后的模型）

- **只有两种模式**（外加默认 crypto），级别清晰：
  - **crypto（默认）**：K 存 OS 安全存储 / `file`；单因子，稳定性最高。
  - **M1 口令（Portable）**：自含；跨端/换机复制 + 口令即可解。
  - **M2 增强（Device-bound）**：本机绑定（m2a 口令+设备+恢复码 / m2b 仅设备，后者**本机级·较弱**）；**m2a** 离线窃取仅得密文无法解；**m2b** 仅凭同用户可读的 `device.key` + vault 文件即可离线解出全部明文（单因子）。
- **同一容器格式（`'S'`）、同一条 AEAD/条目路径**（减少体积与代码面）。
- **协议加固（✅ 去 env 信任已落地；OS peer-cred IPC 未落地）**：不再信任可伪造的 env / argv；父进程身份由 OS 提供。
- **应用层完整性（✅ 已落地）**：key1 签名清单（尽力覆盖"仅替换文件"，不承诺防替换主程序）。
- **低资源 / 高效率 / 安全传输**。

---

## 3. 密码学选型

| 组件 | 选择 | 理由 |
|---|---|---|
| 口令 KDF | **Argon2id** | 内存硬；已有 C# 实现；参数**用户可选**（`--kdf-m/--kdf-t/--kdf-p` + `set-kdf`）；**默认档** `m=64 MiB / t=3 / p=1`（未做按设备校准/自适应） |
| 条目 AEAD | **AES-256-GCM**（仅此一种） | AES-GCM 有硬件加速（x86/ARM）最快；header 记录算法 id（`alg=1`）。**未做 ChaCha20-Poly1305 回退** |
| 设备因子 | HKDF-SHA256(deviceSecret) | 设备密钥高熵，**不**做重 KDF（避免二次开销）；`deviceSecret` 存本地 `device.key`（0600） |
| header 认证 | HMAC-SHA256(K, header‖entries) | 防篡改/防降级/防"塞入他人 vault"（含 vaultId / 槽位 AD = vaultId‖kind） |
| 传输（IPC） | 会话一次性密钥 + 父进程身份（OS 提供） | 仍 stdio 文本行；OS peer-cred 未落地，见 §5 |

> **不引入新 AEAD 自研**：只用成熟原语（AES-GCM / ChaCha20-Poly1305 / Argon2id / HKDF / HMAC）。
> "增强"体现在**密钥管理与协议**，而非自造密码算法（自研算法是风险，不是增强）。

---

## 4. 两种模式

### M1 口令模式（Portable，自含）
```
K = Argon2id(password, salt, params)
vault = header{magic,ver,vaultId,kdf,salt,alg} + entries(AEAD_K) + trailer(HMAC_K)
```
- 无任何外部依赖；换机复制文件 + 口令即可解。
- 丢失点：只有口令（强口令提示 + 可选密码提示语，不存明文）。

### M2 增强模式（Device-bound）
- **两种子模型，二选一（避免多槽膨胀）**：
  - **M2a 双因子（推荐）**：`K` 由「口令+设备」槽封装，`KEK = HKDF(Argon2id(password) ‖ deviceSecret)`。
    `deviceSecret` = 每安装随机 32B，落本地 `device.key`（0600）（**⚠️ 尚未接入 OS 钥匙串**，当前仅文件）。
    离线窃取只拿到 vault 文件 → 缺 deviceSecret **且**缺口令 → 不可解。
    **防丢失**：创建时生成 **高熵 recoveryKey（一次性显示；强提示抄写但可跳过）**，其以独立「恢复槽」封装 K
    （等价第二个"钥匙槽"）——即"双因子 + 恢复钥"共 2 条解锁路径（**不是**多槽膨胀）。
    **无法强制用户抄写**：跳过即"任一因子丢失 = 只能重建"。彻底不可恢复时走 **设置 → 存储 → 重置**
    （销毁 vault + `device.key` + `.bak`，重新登录）。
    **⚠️ 未落地**：设置页常驻提醒、以及"凭当前口令重新生成恢复码"——**代码中无该命令**，恢复码仅初始化时输出一次，丢失无法补发；主进程可用 `init-m2a` 返回的恢复码提示用户保存。
  - **M2b 设备单因子（无口令，可选 · 本机级·较弱）**：`KEK = HKDF(deviceSecret)`，仅需 `device.key`，本机免密。
    安全级别 = 与 `device.key` 存储同档（本地文件被窃即失守；**同用户可读**——读到 `device.key` + vault 即离线解出全部明文，已实测确认）；**推荐 m1/m2a**，UI **须显式告警「本机级（较弱）」**。
- **级别声明**（解决"级别不明确"）：
  - M1 = **口令级**（离线攻击需破口令，KDF 硬）。
  - M2a = **口令+本机级**（离线攻击需同时破口令与窃取 deviceSecret）。
  - M2b = **本机级**（无口令，仅本机；明确弱于 M2a）。

> **为什么不更多槽**：每多一条解锁路径就多一个被攻击面与丢失/覆盖源。M2a 只加 1 条
> **高熵 recoveryKey** 路径用于防遗忘，其余不加——体积与复杂度受控。

---

## 5. 协议加固（防注入的可行部分）

**问题（旧协议）**：曾用 `ARCHOERA_VAULT_PARENT_OK`（调用方注入，可伪造）+ stdin/stdout 明文行。
任何同用户进程都能自造 env 并 spawn vault。

**改造（落地状态）**：
1. **IPC 用 OS 创建的双向通道**（socketpair / 匿名管道 / 命名管道）——**⚠️ 未落地**（当前仍 stdio 文本行）；
   会话密钥由发起方一次性随机，握手绑定（已落地）。
2. **父进程身份由 OS 校验**（不靠自报 env）——**✅ 已落地**（F3）：
   - Linux：读取 `/proc/<ppid>/exe` 与预期路径比对（未用 `SO_PEERCRED`；vault 由父进程 spawn，`getppid`/`/proc/<ppid>/exe` 已足够）。
   - Windows：`NtQueryInformationProcess` + `QueryFullProcessImageNameW`（未用命名管道 peer 校验）。
   - macOS：`proc_pidpath`（未用 `LOCAL_PEERPID`）。
3. **移除可伪造的信任参数**：**✅ 已落地**——不再接受"父进程白名单"env；身份由 OS 提供 pid + 预期 exe 路径。
4. **握手**：会话一次性 challenge + HMAC（✅ 沿用），绑定 `vaultId` / 算法（slots 的 AD = `vaultId‖kind`）。

**仍不可防（如实）**：同用户可自建"父→vault"进程对，OS 只保证"它确实是直接父进程"，
但无法保证"父进程未被篡改"。**这是本地方案的硬上限。**

### 5.1 评估：伪装壳 / 诱饵进程（**不建议** · 未采纳）

设想：伪造一个"壳"骗过注入方，真进程藏在壳里；壳一旦被注入即感知并预防。这属于
**诱饵进程 / 进程镂空（process hollowing）/ 反调试反注入**一类技术，是**恶意软件常见 TTP**。评估：

- **会被 AV/EDR 判定为恶意**：隐藏进程、hollowing、反注入/反调试、自保护/自修改是**行为型启发式**的
  重点特征；即便"善意"实现，也大概率被查杀/隔离。用户看到杀软报警后不会信任本应用；发行侧
  （distro 包、GitHub 发布、企业白名单）也会被标记甚至下架。
- **不能真正防住同用户攻击者**：攻击者能注入壳，就能注入真进程、读 `/proc/<pid>/mem`、或直接替换
  主程序；壳只是**转移目标**。且"检测到注入后的预防动作"（清密钥/退出）本身也可被对手禁用。
- **破坏合法工具链**：调试器、崩溃转储、性能分析、无障碍/辅助工具、与部分反作弊共存都会受影响。
- **与项目红线冲突**：本仓库要求最小权限、普通用户、不装服务/驱动、不做"以管理员运行"的设计；
  引入类恶意软件行为与"透明可信"的发行定位相悖。
- **结论**：**不采纳**。

### 5.2 建议：OS 进程缓解策略（合法、跨端、用户态即可 · **已落地 · best-effort**）

与其"伪装"，不如让 vault 辅助进程**在启动时自施 OS 提供的防注入/防转储缓解**（浏览器同款做法）：

- **Linux**：`prctl(PR_SET_DUMPABLE,0)`、`PR_SET_NO_NEW_PRIVS`、`RLIMIT_CORE=0`、本地密钥缓冲
  `madvise(MADV_DONTDUMP)`；可选 **seccomp** 过滤阻断 `ptrace` / `process_vm_readv|writev`。
- **Windows**：`SetProcessMitigationPolicy` —— **ACG**（禁动态码）、**CIG**（仅可信镜像）、
  ExtensionPointDisable、StrictHandle、CFG。
- **macOS**：Hardened Runtime（**需代码签名，当前不可得**）、`PT_DENY_ATTACH`（需 entitlement，已 deprecated）、
  `setrlimit(RLIMIT_CORE,0)`；无签名时防护有限，**如实声明**。
- **作用与边界**：能**实质阻断"向已启动进程注入"**（ACG/CIG/seccomp 生效时）；但对"攻击者控制进程启动、
  直接替换主程序"仍无效（同 §6 硬上限）。这些是**进程自我保护**，不构成恶意行为，不触发 AV。

### 5.3 可选：蜜罐凭据（仅"检测外泄"，不阻止 · **未采纳**）

在不伪装的前提下，可放一枚**诱饵凭据**（如一条假的流媒体服务器密码）：若日后某处出现该凭据的使用，
即证明发生过外泄。它**不阻止**攻击、且需要上报通道（隐私取舍），仅作事后发现，价值有限。

### 5.4 建议增强：Chromium 式「辅助进程沙箱」+ OS 自我防护（**部分落地**）

> **实际落地（F4）**：只做了「**进程自我保护**」这一层——Linux `PR_SET_DUMPABLE=0` / `RLIMIT_CORE=0` / `PR_SET_PDEATHSIG` +
> **seccomp-BPF denylist**（拒 `ptrace`/`process_vm_readv|writev`/`execve`/`bpf`/内核模块/命名空间/`io_uring` 及 `AF_INET`·`AF_INET6` `socket` → `SECCOMP_RET_KILL_PROCESS`；
> `AF_UNIX` 放行以兼容 libsecret/D-Bus）；Windows `SetProcessMitigationPolicy`（ACG/CIG/ExtensionPointDisable/StrictHandle/CFG/ImageLoad，best-effort）；
> macOS 仅 `RLIMIT_CORE=0`。**未落地**：Linux namespace（user/pid/mount/net）沙箱、Windows 受限令牌/Low IL/Job Object/AppContainer、
> macOS seatbelt / Hardened Runtime、以及"沙箱内无 socket"（因需放行 `AF_UNIX` 供 libsecret）。下述为当时的设计建议，**勿视为现状**。

模型：vault 仍是**独立最小权限辅助进程**（broker=主程序启动它），但启动即**自施沙箱与自保护**，
只保留"读写自身数据目录 + stdin/stdout IPC"所需能力——**无网络、无其它文件、无进程操作**。

**收益（合法、不触发 AV，浏览器同款）**：
- **即便 vault 进程被劫持/注入，也无法联网外泄、无法越权读写文件**——把损害限制在沙箱内；
- 显著收窄注入面（拒绝 `ptrace`/`process_vm_*`/动态码），配合 §5.2 自保护形成纵深。

**平台可行性（普通用户即可，不装服务/驱动，符合仓库红线）**：
- **Linux（最佳）**：非特权 **user+pid+mount+net namespace**（`unshare` + `no_new_privs`）；
  **seccomp-BPF 白名单**（仅文件/内存/futex/时钟/随机数等，拒绝 `socket`/`connect`/`ptrace`/
  `process_vm_readv|writev`/`bpf`/`kexec`…）；`PR_SET_DUMPABLE=0`、`RLIMIT_CORE=0`、`MADV_DONTDUMP`；
  mount namespace 仅数据目录可写、其余只读。
- **Windows**：受限令牌 + Low IL + **Job Object** + `SetProcessMitigationPolicy`
  （**ACG/CIG**/win32k lockdown/ExtensionPointDisable/StrictHandle/CFG）；可选 **AppContainer**。
- **macOS**：seatbelt `sandbox_init`（deprecated，无签名时能力受限）；Hardened Runtime **需签名（当前不可得）**
  → 本机**只做自我防护**（`RLIMIT_CORE=0`、`mlock`/`madvise`），沙箱能力**如实声明受限**。

**与键管理协同**：沙箱要求 vault **无 IPC/网络**——因此 M2 的 `deviceSecret` **优先用本地 0600 文件**
（无需 D-Bus/钥匙串），避开平台 IPC；若用 OS 钥匙串则需放行对应 socket（削弱沙箱，需权衡）。

**边界（重要，勿高估）**：沙箱保护的是 **vault 辅助进程**。**主程序（需联网 + 读写音乐库）无法沙箱**，
且它**合法发起解锁并临时持有明文**——若**主程序被攻陷**，沙箱无法阻止其外泄。故 §6 的硬上限不变：
无 OS 代码签名/硬件安全模块时，"替换主程序/同用户运行期注入主程序"仍不可防。

### 5.5 评估：「被毁前先自毁 / 自崩溃」（区分两类，切勿混淆 · ① 已落地 / ② 未采纳）

有合法先例（HSM/TPM 的篡改清零、全盘加密的自毁 PIN、异常退出时零化内存密钥）。但必须拆成两类：

**① 会话级 fail-closed 自毁（合法、低风险，建议做）**
- 检出异常/篡改（握手失败、锚点不符、完整性校验失败、异常终止）→ **立即零化内存密钥、
  终止 vault 进程、拒绝继续服务**（`exit` fail-closed）。**只销毁"内存中的会话态"，不碰持久数据。**
- 现有实现已有雏形（`exit(86)`、mlock 缓冲 zeroize、锚点不符拒绝），可强化为"任何完整性失败即 fail-closed"。

**② 持久数据自动擦除（强烈不建议）**
"检出注入就删除/覆写 vault 文件"看似痛快，实为**自我伤害**：
- **DoS 化**：对手控制环境即可**主动触发擦除**——"在真被毁掉前先毁掉自己"恰恰是**对手想要的结果**，
  等于把防御变成**攻击用户数据**的手段。
- **误报=灾难**：AV/EDR 注入、调试器、崩溃、OOM、内核/系统更新、无障碍工具都可能被误判为"注入"
  → **正常用户凭据被抹除**。
- **靠不住**：能注入的对手同样能**禁用该检查**；软件层无法可靠区分"是否正在被抽取密钥"。
- **恶性特征**：按启发式毁灭数据属破坏性行为，易被 AV/EDR 判恶意，也违背"透明可信"的发行定位。
- **"利用注入的语法/特性"检测** ⇔ 反调试/反篡改检测，本质同 §5.1，**不可靠且带恶意软件特征**。

**建议的替代（非破坏性 + 用户可控）**：
- **非破坏性响应**：检出即**锁定会话 + 零化内存密钥 + 终止进程 + 显著告警**，由**用户**决定后续
  （重新解锁 / 检查系统 / 主动擦除）。
- **回滚 / 替换保护**：`vaultId` + 版本计数 + trailer MAC，**拒绝**旧状态或他人 vault，而**不销毁**当前数据。
- **可选"恐慌擦除"（opt-in、显式）**：由**用户**通过显式动作触发（按键 / 胁迫口令 → 擦除解密密钥），
  **非启发式自动**；默认关闭并明确告知风险。
- **硬件根**：只有 TPM/Secure Enclave 下的"篡改清零"才有真正价值（硬件可信、不可被软件改写）。

**结论**：做 **① 会话级 fail-closed 自毁**；**不做 ② 持久数据自动擦除**（除非用户显式 opt-in 且充分知情）。

### 5.6 采纳：程序级「自毁」= 进程终止 + UI 告警，**数据不动**（**已落地**）

用户澄清目标：**突破时只终止进程**（连带 UI 显著告警），**绝不删除持久数据**。与 §5.5 ① 一致。
关键点：**不依赖启发式注入检测**（不可靠、带恶意特征），而是**借 OS 强制**实现"突破尝试即进程被终结"：

- **OS 强制终止即"自毁"**：
  - **Windows ACG**（`ProcessDynamicCodePolicy`）：任何动态代码/注入尝试 → **OS 直接终止进程**
    （`STATUS_DYNAMIC_CODE_BLOCKED`）；**CIG** 阻止加载非可信镜像。vault 为 NativeAOT（无 JIT），
    与 ACG 天然相容（实现时逐项验证，不兼容则回退 CIG/其它缓解，**不影响正确性**）。
  - **Linux seccomp**：触发被禁系统调用（`ptrace`/`process_vm_readv|writev`/`socket`/`connect`…）→
    `SECCOMP_RET_KILL_PROCESS` → **`SIGSYS` 终止进程**。
  - 即："突破尝试 = 进程被 **OS** 杀死"，**无需自己判定注入**，也**不是**伪装/反调试。
- **父进程 fail-closed + UI 告警**（扩展已有雏形）：vault 异常终止 / 完整性校验失败 / 锚点不符 →
  主进程按 fail-closed 处理（已有 `exit(86)` + `VaultCrashGate`），并弹**安全告警**：
  "检测到异常/可能被干预，已终止以保护凭据；请从官方来源重装或核查系统环境"。
- **零化内存密钥**：终止/异常退出路径 zeroize mlock 缓冲（已有），**内存态不残留**。
- **数据不动**：持久 vault 文件保持不变；重启后重新解锁即可——**这正是"不擦数据"换来的安全**。
- **副作用（可接受）**：误报只造成"一次重启 + 告警"（非数据损失）；攻击者可借此制造反复重启（DoS），
  但**不影响数据完整性**。
- **硬上限（不变）**：若**主程序**被攻陷，UI 告警与终止都不可靠（对手可禁用）；无代码签名/硬件时无解。

> 与 §5.5 ② 的区别：**自毁 = 进程死（会话态清零）**；**≠ 数据毁**。前者保护用户，后者伤害用户。

### 5.7 沙箱即传感器：突破沙箱必留下可检测事件（**部分落地**）

用户洞察（对 **vault 目标**成立）：要注入/操纵 vault 的代码，攻击者通常**必须先绕过或突破它的沙箱**——
而沙箱由 **OS 内核强制**，绕过尝试必然触发 **OS 可见事件**，于是**沙箱本身就是入侵传感器**：

- **Linux**：被 seccomp 拒绝的 syscall → `SIGSYS`（或配 `SECCOMP_RET_TRAP`/`LOG` 先记录）；
  `no_new_privs` 阻止提权；mount/net namespace 阻止越权与联网——**每一步失败都是明确事件**。
- **Windows**：**ACG** 动态码 → `STATUS_DYNAMIC_CODE_BLOCKED` **终止进程**；**CIG** 非可信镜像加载失败
  （可开 **audit** 模式记录不阻断，用于观测）。
- **父进程映射为安全事件**：vault 因"沙箱违规"异常终止（可由退出信号/码区分）→ 主进程 **fail-closed**
  （已有 `exit(86)` 路径）并弹 **UI 告警**（扩展 `VaultCrashGate`）。
- 可对**绝不该出现的 syscall** 设 `SECCOMP_RET_KILL_PROCESS`（立即杀）或 `TRAP`+自处理（先记录再退），
  两者都能被父进程感知——这就是"**突破必经可检测路径**"的落地。
- 属**合法**技术（纵深防御/最小权限），**非**反调试伪装；不引入 `§5.1` 的恶意特征。

**边界（必须说清，勿高估）**：
- 该传感器覆盖**以 vault 为目标的攻击**。若攻击者**直接攻陷主程序**（无沙箱、需联网、合法持有明文），
  他**无需触碰 vault 沙箱**，传感器**不会响**——硬上限不变。
- "可检测"是**高概率**而非**保证**：内核漏洞、或仅用被允许 syscall 完成的操作仍可能绕过；**不承诺 100%**。
- 传感器只**终止会话 + 告警**，**不擦数据**（§5.5 / §5.6）。

### 5.8 进程联动的含义：vault 死 → 主程序同死 → 告警落在"下次启动"（**已落地**）

用户观察正确，且这**简化**了告警设计：
- 现状（合理）：`VaultProcess._record` 在 vault **非预期退出**时写标记并 `_abort` → 主程序 `exit(86)`。
  即 **vault 被干掉，主程序随之被干掉**——因此**没有"实时 UI 告警"的机会**（进程已不存在）。
- 所以告警**只能是**"持久化标记 + **下次启动**的 gate"（已有 `VaultCrashGate` 消费 `vault.marker`）。
  我们要做的是：让**安全事件**（完整性失败 / 沙箱违规）写入**可区分的标记**，下次启动给**明确的安全文案**
  （而非普通崩溃文案）——**无需**设计实时告警。
- 为什么仍"连坐"主进程：vault 意外死亡时，主程序内存中可能仍有**已按需解密的明文**（SEC-03 后量更小但非零）；
  fail-closed 连坐可**立即回收内存**，不给被攻陷会话继续运行的窗口。
- 代价：攻击者/环境（沙箱误报）可反复触发"vault 死 → App 退出"的 **DoS**；但**不泄露、不破坏数据**，
  重启后重新解锁即可——可接受，如实声明。
- 若将来想"不连坐"（App 存活、仅锁凭据并要求重解锁），前提是**确保 App 侧无明文残留**（与 SEC-03 方向一致），
  但会**降低 fail-closed 强度**，需权衡；本期维持"连坐"。







---

## 6. 防替换（可行部分 · **已落地**）

- **应用层 key1 签名清单**：构建期生成 `native/` 全部文件（含 vault 二进制）的 SHA-256 清单，
  用 key1（ECDSA P-256，离线私钥）签 `.sig1`；运行期用**内嵌公钥**校验签名 + 逐文件哈希，
  **fail-closed**。→ 攻击者无 key1 无法同时改文件与清单。
- **vault 二进制**在 spawn 前用该清单校验（取代可伪造的 `ARCHOERA-VAULT-PROD-*` marker 作为主防线；
  marker 仅保留"防误用测试构建"的原有用途）。
- **硬上限（如实）**：**替换主程序 / 在进程内注入**不可防——验证逻辑本身在可被替换的进程里。
  无 OS 代码签名 / 无 TPM·SecureEnclave 时，任何"自证"都可被绕过。此项**不承诺**。

> 覆盖说明：release 作业能自行打包的产物（macOS/Windows tar、原始 bundle）可注入签名清单；
> deb/rpm/AppImage/flatpak 由**发行版包管理器签名**承担、Windows 安装器由发布 `.sig1` 在安装前核验。
> 无法注入签名的产物在应用内退化为**哈希仅检**（仍防误改/损坏，非确定性攻击）。

---

## 7. 防爆 / 防丢失

- **参数（已落地）**：`VaultLimits` 同时设上限与**下限**（实际：`m∈[8192 KiB, 256 MiB]`、`t∈[1,16]`、`p∈[1,8]`），
  越界/低于下限 → 解密前拒绝（防"替换成弱 KDF 槽"降级，也防解锁前 DoS）。
- **强度用户可选（已落地）**：`init-m1`/`init-m2a` 可经 `--kdf-m/--kdf-t/--kdf-p` 选档；`set-kdf` 无数据损失重封装口令槽（保持 K 与条目；m2a 另需 `device.key`；crypto/file/m2b 不支持，见 §12）。
- **自适应（未落地）**：**未**做"按设备基准校准 KDF"；默认档为 `m=64 MiB / t=3 / p=1`。
- **在线退避（已落地，含残余）**：crypto 模式退避状态内嵌 `master-share`（删除/伪造明文 `vault.lockout` 不重置）；
  **slots 模式**（m1/m2a/m2b）份额现场派生、不入库，仍回退明文 `vault.lockout`——属已声明残余。
  **退避只是在线限速、不是抗离线暴破边界**（离线猜测不过 vault 进程）；按**已接受的低影响残障**处理。
- **防丢失（已落地，含未落地项）**：M2a 的 recoveryKey（高熵、独立恢复槽）用于设备因子丢失/换机；原子写 + `.bak` 回滚。
  **⚠️ 未落地**：设置页常驻提醒、"凭口令重新生成恢复码"（**无该命令**）；不可恢复时经
  **设置 → 存储 → 重置**（`destroy` 删除 vault + `.bak` + `device.key` + 份额/锁定状态）重建——重置须覆盖**全部**解锁材料，否则残留。

---

## 8. 效率 / 体积

- 单容器 + 最小 header；按需解密单条（✅ SEC-03 方向，`loadSecret(id)`）。
  **⚠️ 未落地**：大库流式解密 / 增量写——当前 `VaultFile.Load` **整文件读入**（上限 16 MiB）。
- AEAD 用 **AES-256-GCM**（✅ 已落地，`alg=1`）。**⚠️ 未落地**：无 AES 指令时的 **ChaCha20-Poly1305 回退**——当前仅 AES-GCM 一种。
- 解锁密钥在 vault 进程内短时持有于 mlock 缓冲；主进程不缓存口令（✅ 每次操作按需注入或会话口令）。
- **⚠️ 未落地**：IPC 二进制帧——当前仍为 stdin/stdout **base64 文本行**协议。

---

## 9. 迁移 / 兼容

- **实际（与原文相反）**：**不保留**旧 v1–v4 的读兼容——`ReadHeader` 对非 `'C'`/`'S'` 版本抛「vault 版本不兼容」，
  **无迁移路径**；旧 vault 用户只能重置重建（重新登录）。旧明文 `sessionStore`/`session.json` 的一次性迁移仍保留。
- 因此原文"旧库解锁得 K → 重写为新容器"的迁移流程**未实施**。
- 不再新增 v3/v4 形态（已删除）；crypto（`'C'`）与 slots（`'S'`）为当前唯一两种容器。

---

## 10. 决策记录（原"待评审决策"，已定）

- **D1 → 已采纳**：M1 口令 + M2 增强（M2a 双因子 / M2b 本机单因子）+ crypto（默认）；旧 v1–v3 **移除**（**非**读兼容）。
- **D2 → 已采纳**：M2a recoveryKey 一次性输出；跳过即"因子丢失 = 重置"（**未实现**重新生成）。
- **D3 → 已定**：AEAD 单用 **AES-256-GCM**（未做 ChaCha20 回退）。
- **D4 → 部分采纳**：**去 env 信任**已落地（F3，移除 `ARCHOERA_VAULT_PARENT_OK`）；**socketpair + OS peer-cred + 二进制帧 IPC 未落地**（仍 stdio 文本行）。
- **D5 → 已落地**：应用层 key1 签名清单（F5，`ARCHOERA-NATIVE-MANIFEST.sig1`；release 作业注入签名，覆盖面见 §6）。
- **D6 → 部分落地**：仅**进程自我保护**（F4）；完整沙箱（namespace / AppContainer / seatbelt）**未落地**，见 §5.4。

---

## 11. 实施路线（已执行状态）

1. **F1 收敛格式与模式（✅ 已落地）**：容器统一为 crypto `'C'` / slots `'S'`（m1 / m2a / m2b）；最小 header + trailer MAC；旧模式**移除**（非读兼容）。
2. **F2 解锁/恢复（✅ 已落地）**：口令槽 + 设备槽 + 高熵恢复槽；KDF 参数上下限；原子写 + `.bak`。（"重新生成恢复码"未实现。）
3. **F3 进程协议加固（✅ 部分）**：**去 `ARCHOERA_VAULT_PARENT_OK` env 信任**已落地（OS 提供 pid + exe 路径）；**socketpair/OS peer-cred 与二进制帧 IPC 未落地**。
4. **F4 沙箱 + 自保护（✅ 部分）**：Linux（`DUMPABLE=0`/`RLIMIT_CORE=0`/`PDEATHSIG` + seccomp-BPF denylist）、Windows（`SetProcessMitigationPolicy` ACG/CIG 等）、macOS（仅 `RLIMIT_CORE=0`）；**namespaces / Job Object / seatbelt 未落地**。
5. **F5 应用层完整性（✅ 已落地）**：key1 签名清单（native/vault），spawn 前校验 vault；release 作业注入签名。
6. **F6 迁移与回归（⚠️ 调整）**：旧 v1–v4 **不迁移**（重置）；`test.sh` 覆盖新模式全链路 / 篡改 / 退避。

> 每阶段独立可回归；F1/F2 为先决，F3–F5 为纵深，F6 收口。


> **底线声明**：本方案能**显著**改善"离线窃取、弱口令暴破、单点丢失、部分文件替换"；
> **不能**在没有 OS 代码签名或硬件安全模块时防住"同用户运行期注入/替换主程序"。
> **当前取向**：OS 代码签名（macOS 公证 / Windows Authenticode）**不推进**，应用层以 **key1 签名清单**为真实性机制（F5），
> 上述硬上限作为**已声明残余**保留；若将来该硬需求成为硬约束，唯一现实路径仍是 **macOS 公证 / Windows Authenticode 或 TPM·SecureEnclave**。

---

## 12. 对抗测试发现（2026-10，本地实测）

对 `archoera-vault-test` 子进程做了 16 项攻击，**防御成立 14 项、发现 2 个缺口**：

**成立**：伪造 `ARCHOERA_VAULT_PARENT_OK` 无效（打包布局仍按父进程 exe 拒绝）；dev 布局放行（已声明）；`PR_SET_DUMPABLE=0` 下 `/proc/<pid>/mem`、`gcore`、`gdb -p` 全部被拒；seccomp 生效且拒绝 `AF_INET` socket（放行 `AF_UNIX`）；握手前不能注入 `get`；旧 `'P'` 格式拒绝（版本不兼容）；m2a 仅凭 `device.key` 解不开（口令仍必需）；单次错误口令 ~407ms（Argon2id 64MiB/t=3）。

**缺口 1 · slots 退避可被同用户重置（C2）**：slots 模式无份额槽 → 退避落在明文 `<dataDir>/vault.lockout`，**删除该文件即可清零退避**（实测删除后再试不再"锁定"）。与 SEC-05 同类：**任何软件态退避在"能删状态的同用户攻击者"面前都不可强制**（离线暴破本就无法限速）。**真正杠杆是 KDF 成本 + 口令/恢复码熵**。缓解：可选把退避同时写 OS 安全存储（Windows/macOS 提升删除成本，Linux libsecret 同用户仍可读/删）；文档如实声明。

**缺口 2 · m2b 为单因子（H2）**：m2b 仅设备槽，**读到 `device.key`（0600，同用户可读）即离线解出全部明文**（实测仅凭 `device.key` + vault 文件成功解出凭据）。属 m2b 的定义使然（本机级、弱于 m2a）。建议：UI 明确标注"本机级（较弱）"或直接不提供 m2b 入口（Vault 保留支持）。

**已定决策（2026-10 复核，对应上述发现）**：

- **(a) m2b 保留但明确标弱**：m2b 为**本机级（较弱）**单因子，**保留为受支持的弱选项**（**不移除**入口，Vault 保留支持）；UI 须明确标注「本机级（较弱）」，**推荐 `m1` / `m2a`**，高价值凭据不用 m2b。m2b 相对 crypto（桌面走 OS keystore）与 m2a **基本冗余且更弱**。
- **(b) 退避缺口按低影响残障接受**：**离线暴破不走 vault 进程**，`vault.lockout` 只约束**在线 / 交互**路径，属**已接受的低影响残障**；不做"加密退避 / fail-closed 退避"（会误伤正常客户端，与设计取舍不符）；抗暴破依赖 **KDF 成本 + 口令 / 恢复码熵**。
- **(c) KDF 强度改为用户可选**：`init-m1` / `init-m2a` 支持 `--kdf-m/--kdf-t/--kdf-p`；新增 `set-kdf` **无数据损失重封装**口令槽（保持 K 与全部条目，仅重封装口令槽并重算尾部 HMAC；m2a 另需 `device.key`；crypto/file/m2b 不支持）；应用拟暴露 **低 / 中 / 高** 三档预设（`32 MiB/t=3` · `64 MiB/t=3` · `256 MiB/t=4`）。

**其余固有边界（已声明，非缺陷）**：dev 布局不 pin 父进程路径（保 `flutter run`）；同用户可读 `device.key`/vault 文件（无 OS 隔离即无解）；替换主程序/同用户运行期注入主程序超出本地防线（key1 签名清单 + 沙箱只提高门槛/检测部分替换）。

---

## 13. 非常规撬开尝试与修补（2026-10，本地实测）

在 §12 规范攻击之外，做了"非常规"尝试（LD_PRELOAD / 环境注入 / 伪造 vault / 父进程伪造）：

- **A · LD_PRELOAD 注入（曾经成立，已修）**：vault 为动态链接 PIE、继承环境；`LD_PRELOAD=<evil.so>` hook `read` 即可读到标准输入握手里的明文口令 → 再用该口令离线解出全部凭据（**实测完全失守**）。
  - **修补**：① Dart 侧 spawn vault（`start`+`runSync`）改用**净化环境**（剔除 `LD_PRELOAD`/`LD_AUDIT`/`LD_LIBRARY_PATH`/`DYLD_*`，并以 `includeParentEnvironment:false` 不再合并父环境）；② vault 侧 `VerifyAndArm` 在 Linux 检出 `LD_PRELOAD`/`LD_AUDIT` 非空、macOS 检出 `DYLD_INSERT_LIBRARIES` 非空即**拒绝运行**（在读任何输入之前）。
  - **残余**：属"提高门槛"而非边界——系统级 `/etc/ld.so.preload`、或已被攻陷的父程序注入不受控。**根治办法是静态链接**（`ld.so` 不参与，`LD_PRELOAD` 失效）——**Linux 已落地**：`native/archoera-vault` 改由 `app/core/vault-rs` 的 **Rust 静态单文件**承接（`+crt-static`；CI 走 musl 静态），C# NativeAOT 因链接器断言失败无法静态化（§13-E）。**Windows / macOS 仍用 C# vault**，其加载器注入只靠过程护栏（`VerifyAndArm` 拒绝非空注入变量）+ Dart 侧环境净化。
- **B · `/proc/<pid>/environ`**：被 `PR_SET_DUMPABLE=0` 拒绝（口令也不经 env 传递）。
- **C · `ARCHOERA_VAULT_BIN` 伪造 vault（曾经成立，已修）**：应用会把明文口令交给 env 指定的二进制，而 marker 与握手 HMAC 均可自算，**不构成对 vault 二进制的认证**。
  - **修补**：`ARCHOERA_VAULT_BIN` **仅在 debug/测试构建生效**（`kDebugMode`；或显式 `ARCHOERA_ALLOW_VAULT_BIN`）；**release 忽略**，走默认解析 + key1 签名清单校验 + 父进程身份校验。
- **D · 伪造"主程序"满足父进程 pin**：把一份 fork 包装器命名为 `archoera_music` 放在打包布局的预期路径，vault 即接受（已验证 pin 可通过）。此为**"替换主程序"的已知上限**，本地防线无法阻止。
- **E · 静态链接**：NativeAOT `-r linux-musl-x64 -p:StaticExecutable=true` 在本机 `ld.bfd` 断言失败 → 暂不可得（若换环境可尝试 `lld`）。**已改走备选**：Linux 用 Rust（`app/core/vault-rs`）静态单文件（`+crt-static`；CI 走 musl 静态）替代 C# NativeAOT，从根上消除 `ld.so` 参与。

## 14. 多端"需真机验证"清单（本地仅 IL 交叉编译）

已在本地通过：`dotnet build -r win-x64 / osx-x64 / osx-arm64 / linux-arm64 / linux-musl-x64` 均 0 error；`vault/test.sh`（Linux）全绿；`dart analyze` 0 issue。**Linux 现用 Rust 版**：`app/core/vault-rs/test.sh` + `app/core/vault-rs/cross_parity.sh`（与 C# 双向互解互读）均已本地全绿。以下**必须在对应真机/CI 复验**：

- **macOS**：`libproc.dylib` 符号在 Apple Silicon 的解析；Keychain `SecItem*` 运行时（`kCFType*CallBacks` + UTF-8 CFString 修复后的实际可用性）；`.app` 单一 `native/` 目录（Xcode 与 CI 一致）后的端到端打包与加载；**NativeAOT 跨端 publish**（Linux 无法交叉 AOT）。
- **Linux aarch64**：`libsecret` 可变参 P/Invoke（仅 x86-64 验证过）；`g_str_hash`/`g_str_equal` 在真实 Secret Service 下的读写。
- **Windows**：DPAPI 路径；`File.Move`/`File.Copy(overwrite)` 在 AV/索引器占用下的瞬时失败；父进程 `QueryFullProcessImageNameW` 路径比较；`Process.runSync` UTF-8 解码。
- **三端**：加载器注入拒绝（Linux 已测；macOS `DYLD_INSERT_LIBRARIES` 待真机）；`ARCHOERA_VAULT_BIN` 在 release 被忽略（需打包后验证）。
