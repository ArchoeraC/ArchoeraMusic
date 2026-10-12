# 凭据保险库规划

> 状态：**已实施（vault-1 ~ vault-4 + 第六步口令模式全部完成，2026-08-12）**；**2026-10 重构后模式收敛为 crypto / slots（m1 / m2a / m2b）**——详见下方重构说明。
> ⚠️ 已知缺口与待修复项见 [security-review-2026-10-11.md](security-review-2026-10-11.md)（本计划的补强台账）。
> 定位：把本地凭据（流媒体服务器密码、网易/酷狗 session）从「明文落盘 + 进程存活期明文」改造为
> **静态加密存储（vault）+ 按需流式解密 + 运行时内存保护 + 一键销毁**，防磁盘泄露与「销毁即失效」。
>
> **⚠️ 2026-10 重构说明（阅读本文历史章节前必读）**：
> 旧的 **v1（OS 2-of-2）/ v2（口令）/ v3（设备密封 · 多封装）** 三档与 v4-file 分层**已移除**，
> `DeviceEntropy.cs` / `Fingerprint.cs` 删除；命令 `init` / `init-password` / `init-device` /
> `switch-mode` / `upgrade-device` / `rebind` / `clear-device-seal` / `set-recovery-password` /
> `clear-recovery-password` **全部移除**。**无迁移**：旧 vault 文件启动报「vault 版本不兼容」，用户重置。
> 现行模式（本文 §3 已更新，历史 §6/§8 描述为旧实现，仅供审计溯源）：
> - **crypto（默认，`'C'`）**：主密钥 K 整体存 OS 安全存储（DPAPI/Keychain/libsecret）或 `file` 后端
>   （`secret.key` 0600）；vault 文件不含密钥材料；**单因子**；OS store 键按数据目录作用域。
> - **slots（`'S'` 容器）**：头部槽位表封装 K + 条目以 K 加密 + 尾部 `HMAC-SHA256(K, header‖entries)`；
>   三种因子模式 **m1**（口令）/ **m2a**（口令 + 本地 `device.key` + 一次性恢复码）/ **m2b**（仅 `device.key`，免密）。
> 本轮同时落地 **F3** 父进程身份校验（移除 `ARCHOERA_VAULT_PARENT_OK`）、**F4** 进程自我保护、
> **F5** key1 签名的原生完整性清单（应用层信任根，取代 OS 代码签名承诺）；细节见
> [vault-enhanced-scheme.md](vault-enhanced-scheme.md) / [vault-security-notes.md](vault-security-notes.md)。
>
> 实施要点速览（相对规划的偏差）：
> - **vault 核心用 C#（NativeAOT）独立进程，而非 Go FFI 承载**——按用户决策「仅凭据模块用 C# 重构」落地；
> - 五步落地（§6）已全部完成；验证计划（§7）主项已通过，三平台 keyring 真机验证待做；
> - 详细实施记录见 §8「实施记录与测试」。

---

## 1. 背景与现状

### 1.1 凭据现状（明文风险）

| 凭据 | 现状存储 | 使用路径 |
|---|---|---|
| 酷狗 session（token/userid） | `sessionStore`（kugou_api.dart L57-68）**明文持久化** | 下载时明文读出 → FFI `setKugouSession`（download_controller.dart L505） |
| 网易 cookie（MUSIC_U 等） | `sessionStore` 明文 | FFI `setNeteaseCookie`（L510）/ HTTP cookie 构造（request.dart L229） |
| 流媒体服务器密码 / 本地 Subsonic 账号 | 既有凭据管理 | 注入 config JSON |

- **静态风险**：明文落盘 → 磁盘泄露、备份、取证即泄密；
- **运行态风险**：登录后 token 明文常驻 Dart 内存（sessionStore 对象 / 状态缓存），生命周期=进程存活期；
- 已有基础设施：设置页「清除所有本地凭据」入口（l10n 已含，irreversibly deletes all local account credentials）；Go 桌面端已具备「凭据加解密」FFI（桌面端/服务端共享）。

### 1.2 安全边界（四条客观认知，方案的前提）

1. **明文最终必进内存**：请求头构造、签名计算、FFI 传字符串都需要 token 明文。流式解密只能**缩短明文驻留时长、减少明文副本**，无法做到「内存无明文」；
2. **加密防「静态数据泄露」，不防「运行时内存读取」**：攻击者若能 dump 进程内存（同用户权限可行），密钥与解密后的明文都在内存中——此威胁模型由 OS 级隔离承担，加密不负责；
3. **密钥绝不能硬编码/内置**：否则加密形同虚设。密钥必须来自「OS 安全存储」或「用户口令派生」，且主密钥与密文分开放置；
4. **开源约束（Kerckhoffs）**：本项目代码全开源，安全**不得依赖算法/实现保密**——攻击者可按源码重实现任一模块（反向模块）。因此：
   - 签名盐混淆、握手协议的「协议保密」均不构成安全支柱；
   - **OS 安全存储（DPAPI/Keychain/libsecret）的定位不降级**：它仍是纵深防御的关键一层——密钥材料受系统级保护（用户登录凭据/TPM 绑定、钥匙串授权策略、桌面会话），拦得住「无同用户代码执行权的攻击者」（静态磁盘泄露、备份、取证、其他用户）；对同用户恶意进程虽可被调用解锁，但解锁受系统授权与失败校验约束，并非裸明文——**不能作为唯一防线，需与其他层叠加**；
   - 本地防线（纵深叠加，逐层提高爆破成本）：**OS 安全存储**、**用户口令（Argon2id memory-hard，天然防 GPU 爆破）**、**解锁失败退避/速率限制**、**凭据短时效 + 平台侧吊销**、**系统账户边界**；
5. **信任根边界（主程序进程）**：vault 的全部防线（父进程身份校验、握手、fail-closed）都建立在「主进程可信」的前提上。攻击者**同时替换主程序（Dart 可执行 / FFI 库）** 或**在主进程内嵌主动联网上传程序段**时——FFI 库运行在主进程内，主进程本身即 vault 的合法握手对象，vault 无从区分被篡改的主程序，会在明文窗口被截获凭据并外传。此类威胁（进程注入 / 信任根攻破）**超出应用层能力**。
   **2026-10 处置**：**OS 代码签名不再推进**（Windows Authenticode / macOS 公证因成本与步骤不可得）。当前应用层信任根为 **key1 签名的原生完整性清单（F5）**——清单 `ARCHOERA-NATIVE-MANIFEST.txt` 由 key1 签为 `.sig1`，运行期用内嵌公钥**先验签、再比对摘要**（fail-closed），vault 二进制 spawn 前校验；分发渠道（deb/rpm/AppImage/flatpak 等）依赖**包管理器签名**、Inno `.exe` 依赖外层 `.sig1`。**残余硬上限如实保留**：替换主程序 / 同用户运行期注入主程序**不可防**（验证逻辑本身在被替换的进程里），无 OS 签名 / 硬件根时无解；详见 [supply-chain.md §2](supply-chain.md) 与 [vault-security-notes.md](vault-security-notes.md)。

---

## 2. 目标

1. 凭据**静态加密**：磁盘上只有密文，无任何明文副本；
2. **可销毁性**：销毁 vault 文件 = 本地 token 永久失效（明文从未落盘，无法恢复）；
3. **按需流式解密**：注入/请求前短时解密单条凭据，用后即弃，缩短明文生命周期；
4. 主密钥安全：**crypto（默认，OS 安全存储 / file）**、**slots m1（口令，Argon2id）**、**slots m2a（口令+设备+恢复码）**、**slots m2b（设备，免密）**（§3.2）；
5. 与现有「清除凭据」入口对齐，不引入第二套机制（vault 核心实施为 C# NativeAOT，桌面端 Go 凭据加解密 FFI 保留）；
6. **运行时内存保护**：主密钥与短时明文缓冲 mlock 禁 swap、MADV_DONTDUMP 禁 dump 泄露、release 启动禁调试读取 + 进程自我保护（§3.6）；
7. **崩溃联动（fail-closed）**：凭据模块非预期退出 → 连带主进程终止，内存随系统回收；下次启动显著警告（§3.7）；
8. **按需启动与握手协议**：凭据模块不常驻、按需会话化启动，拒绝独立/脱离主程序的非法启动，会话经握手认证（§3.8）；
9. **应用层信任根（F5）**：key1 签名的原生完整性清单（`ARCHOERA-NATIVE-MANIFEST.sig1`）在 spawn 前校验 vault 二进制，运行期以内嵌公钥验签 + 摘要（fail-closed）；取代 OS 代码签名承诺（§8.5）。

---

## 3. 方案设计

### 3.1 Vault 文件（静态存储）

```
dataDir/
├── credentials.vault        # 全部凭据密文（AES-256-GCM）+ 模式头/槽位表/尾部 HMAC
├── credentials.vault.bak    # 上一版备份（原子写保留；Destroy 一并删除）
├── device.key               # slots m2a/m2b 设备因子（0600；Destroy 一并删除）
└── secret.key               # file 后端主密钥（0600；仅 file 模式）
```

- 容器两种模式（version 字段 = 模式代号，一模式一字母）：
  - **`'C'` crypto（默认）**：`magic "AVLT" | 'C' | reserved(3B) | key_vault(32B 零占位) | backend 指纹 | 条目表`——K 整体存 OS 安全存储 / `file` 后端，**vault 文件不含密钥材料**；
  - **`'S'` slots**：`magic "AVLT" | 'S' | vaultId(16B) | createdAt | alg | 槽位表 | 条目表 | trailer(HMAC-SHA256(K, header‖entries))`——K 由槽位表封装，条目以 K 加密，尾部 HMAC 在解密凭据前校验（verify-before-decrypt）；
- 每条凭据独立 nonce/salt：支持**单条更新与删除**（重写 vault，原子写 + `.bak`）；
- 统一承载：流媒体服务器密码、本地 Subsonic 账号、网易/酷狗 session（对齐「清除所有本地凭据」的覆盖面）。
  **本地 Subsonic 用户密码**以 `uid=subsonic:<username>` 承载（SEC-01，2026-10-12）；服务端认证经
  `archoera_subsonic_set_credentials` 注入内存表，`user.db.password_cipher` 仅空串占位。

### 3.2 主密钥管理（支持的模式）

| 模式 | 代号 / 槽位 | 机制 | 体验 | 安全 |
|---|---|---|---|---|
| **crypto（默认）** | `'C'`，无槽位 | K 整体存 OS 安全存储（Windows DPAPI / macOS Keychain / Linux libsecret）或 `file` 后端（`secret.key` 0600）；OS store 键按数据目录作用域 | 用户无感，随系统账户解锁 | **单因子**：OS 钥匙串被攻破 / `secret.key` 泄露即凭据全泄露；`file` 为显式降级（headless / Docker） |
| **slots m1** | `'S'`，kind=1（口令） | KEK = Argon2id(口令, salt, ad=vaultId‖kind) 封装 K | 解锁时输入口令 | 纯 BCL、自包含；口令弱则全破；遗忘即重置 |
| **slots m2a** | `'S'`，kind=4（口令+设备）+ kind=3（恢复） | KEK = HKDF(Argon2id(口令)‖deviceSecret)；恢复槽由一次性高熵 Crockford-Base32 恢复码解锁 | 日常本机免密，换机/丢 `device.key` 用恢复码 | 双因子 + 恢复码兜底（最强） |
| **slots m2b** | `'S'`，kind=2（设备） | KEK = HKDF(deviceSecret)；仅需本地 `device.key` | 本机完全免密 | **本机级（较弱）**：无口令无恢复、单因子；级别 = `device.key`（0600，同用户可读）存储强度，**读到 `device.key` + vault 即离线全解**（实测）；**推荐 m1/m2a** |

- **开源约束下的定位（§1.2-4）**：OS 安全存储（crypto）仍是纵深关键一层（系统级密钥保护 + 可启用授权策略/凭据绑定/TPM）；**文件密钥（file）为显式降级**，须主动选用、不静默；高价值凭据建议 **slots m2a**（口令 + 设备双因子 + 恢复码）；
- **Linux 无桌面环境（无 Secret Service）**：可选用 `file` 后端（headless）或 slots 模式（自包含，无 keyring 依赖）；
- 旧 v1/v2/v3 分层**已移除**（见文首重构说明）；`destroy` 删除 vault + `.bak` + `device.key` + 份额/锁定状态。

### 3.2.1 slots 槽位封装（取代旧 2-of-2 拆分）

旧版的 **2-of-2 份额拆分（`K_vault ⊕ S`，S 锚定 OS/口令）已随重构移除**——`key_vault` 字段在两种模式下均为 32B 零占位。现行 slots 容器改为**槽位表封装 K**：

```
加密时：随机主密钥 K → 每个槽位以其 KEK 做 AES-256-GCM 封装（ad = vaultId‖kind）：
        · kind=1 口令：      KEK = Argon2id(口令, salt, ad)
        · kind=2 设备：      KEK = HKDF(deviceSecret, salt, "…slot.device")
        · kind=3 恢复：      KEK = HKDF(recoveryCodeBytes, salt, "…slot.recovery")
        · kind=4 口令+设备：  KEK = HKDF(Argon2id(口令)‖deviceSecret, salt, "…slot.pwdev")
解密时：任一槽位可解出 K（OR 语义，多槽为「多解锁路径」而非 AND）；
        解出 K 后立即校验尾部 HMAC-SHA256(K, header‖entries)（verify-before-decrypt）。
```

关键约束：

- **KEK 的熵源必须锚定在攻击者拿不到的地方**（口令记忆 / 本地 `device.key` / 一次性恢复码）——不能只是「主进程本地随机生成后保存」，否则逆向者照源码同样能取得；
- **m2a 的双因子是 AND**（口令 **且** `device.key` 才能派生出 pwdev KEK），**恢复槽是 OR 兜底**（`device.key` 丢失时用恢复码）；vault 文件**不含 deviceSecret**，故「仅窃取 vault 文件」不足解密；
- **m2b 是单因子**（仅 `device.key`）——本机免密的代价是安全级别随 `device.key` 存储强度下降，须显式告警；**本机级（较弱）**，**推荐 m1/m2a**；
- KDF 参数设**上限与下限**（`m∈[8192 KiB, 256 MiB]`、`t∈[1,16]`、`p∈[1,8]`），低于下限防「弱 KDF 槽」降级、高于上限防解锁前 DoS。
- **KDF 强度用户可选（`--kdf-m/--kdf-t/--kdf-p` + `set-kdf`）**：`init-m1` / `init-m2a` 可指定口令承载槽的 Argon2id 参数（缺省默认档 `64 MiB/t=3/p=1`）；`set-kdf` 以**当前口令**无数据损失重封装口令槽——**保持主密钥 K 与全部条目不变**，仅以新参数、新 salt/nonce 重封装该槽并重算尾部 HMAC（原子写 + `.bak`）；口令错误 / 槽被篡改 → GCM 认证失败（fail-closed）；**m2a** 另需 `device.key`（缺失转恢复码流，恢复槽保留），**crypto/file/m2b 不支持**。`status` 对 m1/m2a 回显 `"kdf":{"m":…,"t":…,"p":…}`。应用拟暴露 **低/中/高** 预设（`32 MiB/t=3` · `64 MiB/t=3` · `256 MiB/t=4`）。区间仍受上述上下限约束；**在线退避只约束交互路径，抗离线暴破仍需 KDF 成本 + 口令熵**。

### 3.3 按需流式解密注入

改造现有注入链路（Dart 读明文 → FFI），改为「vault 按需解密 → 短时使用 → 即弃」：

```
登录成功 → 凭据写入 vault（Dart 经 Go FFI 加密存储，Dart 不持有明文）
下载/请求前 → Go FFI 按 platform_id 解密单条 → 返回给 Dart（一次性）
  └─ 酷狗：立即 setKugouSession(userid, token) → 引用置空
  └─ 网易：立即 setNeteaseCookie(cookieHeader) / 构造 HTTP cookie → 引用置空
用后 → Dart 侧不缓存凭据状态对象；Rust 侧缓冲 zeroize 清零
```

- **vault 侧**承载解密——实施为 C# NativeAOT 独立进程 `archoera-vault`（§8.1，非 Go FFI）；桌面端原有「凭据加解密」FFI 保留不复用；
- **Rust 侧**（downloader）：`setKugouSession`/`setNeteaseCookie` 接收后，请求结束时对内部缓冲 `zeroize` 清零（memsec.rs MlockSecret，§8.3）；
- **Dart 侧**：原则上仅注入那一行持有明文、不进状态对象、不落日志（日志长度掩码保留）；
  **已收敛（SEC-03，2026-10）**：`StreamingStore.preloadSecrets()` **不再**批量解密（仅做 vault 惰性初始化与模式探测）；
  凭据由 `StreamingStore.loadSecret(id)` 在真正需要时**按需单条解密**，且**不写回长驻 UI 状态**（`StreamingState` 只保留非敏感元数据；带凭据配置仅临时构造给客户端）。
  **残余（架构性，如实声明）**：Dart `String` 不可 zeroize（GC 管理、会复制），且 §3.6 的 mlock / MADV_DONTDUMP / zeroize **只覆盖
  C#/Rust 缓冲，不覆盖 Dart 侧明文**——被解密的那一条明文在一次会话内仍会短暂存在于堆中。
  缓解为：主进程 `PR_SET_DUMPABLE=0`（拒 ptrace/core dump）+ `RLIMIT_CORE=0`；
  其覆盖范围不含「同用户读 `/proc/<pid>/mem`」（该攻击面仍需 OS 隔离，见 §1.2-2）。见 [security-review SEC-03](security-review-2026-10-11.md)。

### 3.4 销毁流程（可销毁性）

- **全量销毁**（设置-安全-清除所有本地凭据，已有入口）：`VaultService.Destroy` 删除 `credentials.vault` + **`credentials.vault.bak`**（否则重置后残留可解副本）+ **`device.key`**（slots m2a/m2b 设备因子）+ 清进程内已加载凭据 + 调平台登出接口 + 清份额/锁定状态；
- **单凭据登出**：重写 vault（去除该条）+ 清内存缓存；
- 销毁后旧密文不可恢复（明文从未落盘）——实现「变相销毁 token」，即使平台侧 token 仍有效，本地已无可用密文。

### 3.5 迁移

- 首启检测到旧明文 sessionStore：一次性加密迁移进 vault，随后**彻底删除明文存储**（含备份路径）；
- 迁移失败（如 keyring 不可用）→ 保留明文并显著警示，不静默降级。
- **旧 vault 模式（v1/v2/v3）不迁移**：2026-10 重构后 `ReadHeader` 对非 `'C'`/`'S'` 版本抛「vault 版本不兼容」，用户**重置重建**（重新登录），不再保留历史模式的读兼容路径。

### 3.6 运行时内存保护（Linux 机制学习，三平台映射）

「静态加密」防磁盘泄露；「运行时保护」防内存中的密钥/明文被**意外或静态途径拷贝**出去（swap、core dump、调试读取）。

| 能力 | Linux | Windows | macOS |
|---|---|---|---|
| 禁 swap 拷贝 | mlock / mlockall | VirtualLock | mlock |
| 禁 dump 泄露 | madvise(MADV_DONTDUMP) + PR_SET_DUMPABLE=0 | WER UnhandledExceptionFilter 排除敏感区 | MADV_DONTDUMP + 关闭 crash report |
| 禁调试读取 | PR_SET_DUMPABLE=0（/proc/pid/mem、ptrace） | 进程缓解策略（有限） | 受限 |
| 密钥不落用户内存 | kernel keyring（P2 可选） | DPAPI（§3.2 已有） | Keychain（§3.2 已有） |

落地：

- **vault 主密钥**（C# 侧）：分配后 mlock（MemGuard.cs LockedBuffer），销毁时 zeroize + munlock；
- **Rust 明文缓冲**（downloader）：`setKugouSession`/`setNeteaseCookie` 缓冲 mlock 写入 → 请求完 zeroize → munlock（`libc` crate 跨平台，与 §3.3 结合）；
- **release 启动**：Linux 设 `RLIMIT_CORE=0` + `PR_SET_DUMPABLE=0`；macOS 关闭 crash report；Windows 自定义异常处理排除敏感区域；**debug 构建豁免** PR_SET_DUMPABLE（否则断点调试失效）；
- **边界**：这些机制把「意外/静态途径拷贝泄露」的门槛从零防护提升到需 root/内核模块/物理访问；同用户 root 与内核攻击仍在应用层防御范围之外（对齐 §1.2）。

### 3.7 崩溃联动（fail-closed）

攻击者可能诱发凭据模块崩溃以获取 dump/明文。应对：凭据模块异常时**拒绝降级运行**，连带主进程终止、内存随系统回收，下次启动显著警告。

进程模型与联动（vault 为按需会话进程，见 §3.8）：

```
vault 会话进程（按需 spawn，持主密钥，解密经管道短时返回主进程，明文不跨进程常驻）
   │  会话结束 → 主进程 waitpid 校验退出状态（会话级崩溃联动）
   ▼
非预期退出（信号终止 / 空闲超时未退 / 会话中途消失且无正常 shutdown 通知）
   → 主进程立即 abort()（物理内存随系统回收，配合 §3.6 RLIMIT_CORE=0 无 dump）
   → 写 crash 标记文件
正常退出（完成任务自退 / 用户销毁凭据 / 关机：先发「正常退出」通知）
   → 主进程不联动，写 clear 标记
下次启动：读标记 → 非预期 → 显著警告「凭据模块异常退出，本地凭据可能已暴露，
建议重新登录/销毁 vault」并可直接跳转重置
```

配套前提（缺一不可）：

1. **必须与 §3.6 的 `RLIMIT_CORE=0` + `PR_SET_DUMPABLE=0` 配套**：崩溃瞬间若无 core dump 限制，内存仍会被拷到磁盘，「回收」即失效——连带崩溃是最后一层，不是替代；
2. **分层边界**：连带崩溃保护 vault 子进程内的**主密钥**；主进程内的短时明文仍由 §3.6 mlock/DUMPABLE 兜底；
3. **仅「非预期退出」触发**：正常销毁/关机走正常 shutdown 路径（发通知、写 clear 标记），不误判为攻击、不触发警告。

权衡：凭据模块异常会中断播放——安全优先的接受项（对齐 §1.2 边界）。

### 3.8 按需启动与握手协议

vault **不常驻**，按需会话化启动——进程不存在即无攻击面（无法被信号注入/ptrace/劫持），常驻明文窗口消失；同时拒绝独立/脱离主程序的非法启动，会话经握手认证。

生命周期（拒绝内存常驻）：

```
需要加解密时 → 主进程 spawn vault 会话进程 → 握手 → 执行命令 → 会话结束立即自退
空闲超时（如 N 秒无命令）→ vault 兜底自退（防异常常驻）
```

拒绝独立启动（血缘认证）：

- 校验父进程：Linux/macOS `getppid` 必须为主程序进程；Windows 经 ParentPid 校验——独立运行即拒绝；
- `PR_SET_PDEATHSIG(SIGTERM)`（Linux）：主进程死亡 → vault 自动随之退出，防被劫持脱离；
- vault 仅经主进程传入的**匿名管道**收发命令（无管道即拒绝服务），argv/环境不携带任何凭据与握手材料。

握手协议（会话认证，双因子）：

```
主进程：生成随机会话密钥 H + challenge C（m1/m2a 另带口令；m2a 恢复路径带恢复码）
        → spawn vault（argv 仅传数据目录，H/C 与因子经 stdin/管道下发，不回显不落盘）
vault：  校验父进程身份（OS 提供 pid + 可执行文件路径）→ 解锁主密钥（crypto：OS 安全存储 / file；slots：槽位表）
        → 应答 = HMAC-SHA256(H, C) + 构建标记 marker → 经管道回传
主进程：验证应答（HMAC + 锚点 + marker）→ 建立受信会话 → 会话结束即退
```

- 双因子：**进程身份**（父进程校验 + PDEATHSIG）与**主密钥持有**（伪造主进程无法解锁主密钥）；
- **父进程身份校验（F3，无环境变量信任）**：`ARCHOERA_VAULT_PARENT_OK` **已完全移除**——父进程 pid 与可执行文件路径由 **OS** 提供
  （Linux `/proc/<ppid>/exe`、macOS `proc_pidpath`、Windows `QueryFullProcessImageNameW`），与「由 vault 自身位置推导的预期主程序路径」
  （打包布局 `<dir>/native/<vault>` → `<dir>/archoera_music[.exe]`）比对；dev/测试布局放行。**残余（如实）**：同用户攻击者可在预期路径放置自造二进制再 spawn，**无法与「主程序被替换」区分**（L4 硬上限）。
- **进程自我保护（F4，best-effort）**：Linux `PR_SET_PDEATHSIG` + `RLIMIT_CORE=0` + `PR_SET_DUMPABLE=0` + **seccomp-BPF denylist**
  （拒 `ptrace`/`process_vm_readv|writev`/`execve`/`bpf`/内核模块/命名空间/`io_uring` 及 `AF_INET`/`AF_INET6` `socket` → `SECCOMP_RET_KILL_PROCESS`；
  `AF_UNIX` 放行以兼容 libsecret/D-Bus）；Windows `SetProcessMitigationPolicy`（ACG/CIG/ExtensionPointDisable/StrictHandle/CFG/ImageLoad）；
  macOS 仅 `RLIMIT_CORE=0`。全部 best-effort、fail-open，**绝不删除用户数据**；OS 终止经崩溃标记 → 下次启动 `VaultCrashGate`（无实时告警，因主进程 fail-closed 已退出）。
- **握手版本指纹（marker）**：握手应答尾部携带 `BuildInfo.Marker`（PROD/TEST 构建标记）。主进程据此在**协议内**识别 vault 构建——默认路径解析的 vault 必须为 PROD：**缺失或非 PROD（TEST 构建 / 被替换的官方测试二进制）→ 杀进程 + 删除默认路径副本 + 拒绝解密 + 版本异常 fatal 态（UI 仅允许退出，fail-closed）**。
  **定位（勿高估）**：marker 只是**可自报的字符串指纹，无签名 / 无认证**——攻击者可自行编译一个输出同名 `ARCHOERA-VAULT-PROD-*` 的后门 vault 同时通过 `--version` 与握手校验。故该机制**仅防「误用测试构建」**，**不能防「替换二进制」本身**；
  **二进制完整性由应用层 key1 签名清单（F5）承接**——`ARCHOERA-NATIVE-MANIFEST.txt` 由 key1 签为 `.sig1`，运行期内嵌公钥**先验签再比对摘要**（fail-closed），vault 二进制 spawn 前校验（见 §8.5 / [security-review SEC-08/SEC-25](security-review-2026-10-11.md)）；
- **握手前置能力**：vault 在握手完成前**不加载/不解密任何凭据**——未完成握手即崩溃/被终止，也从未产生过明文；主进程会话期间保持管道读端监听 + waitpid，异常退出（EOF）即不信任结果并触发 §3.7 fail-closed；
- 独立运行 vault：无管道、无 H/C → 直接拒绝服务；
- 每次会话的握手密钥一次性，防重放；会话期间所有命令仅经该管道，vault 不响应其他来源；**各模式握手字段数**：crypto / m2b 为 3 字段（免密），m1 / m2a 为 4 字段（口令；m2a 恢复路径为 5 字段，label=`"rec"` + 恢复码）；
- **定位（开源约束 §1.2-4）**：握手防的是「无主进程上下文的独立工具滥用与自动化」，**不承诺防「按源码重实现的攻击者」**——该威胁由强 KDF / 平台侧防线承担。

通信模型（全链路事件驱动，无轮询）：

- vault 等待命令：阻塞 `read(stdin)`，无命令即挂起；
- 空闲超时：`poll/select` 带 timeout 的**单次阻塞**，超时自退（非定时巡检）；
- 主进程感知退出：管道读端 **EOF** + `SIGCHLD`/`waitpid`（Go goroutine + `cmd.Wait()` 阻塞），事件到达才处理，主循环不被占用；
- 命令下发：阻塞写管道；
- 与引擎事件推送计划同思路（能被动感知就不主动询问，全程零忙轮询）。

三平台映射：父进程身份校验由 OS 侧读取父进程 pid + 可执行文件路径（Linux `/proc/<ppid>/exe`、macOS `proc_pidpath`、Windows `QueryFullProcessImageNameW` / `NtQueryInformationProcess`）；父死联动 Linux `PR_SET_PDEATHSIG` / macOS `ParentGone`（getppid 变更）/ Windows `ParentGone`（OpenProcess/GetExitCodeProcess）；随包 stdio 会话三平台均支持。

---

## 4. 改动点清单

> 状态列：✅ 已完成（2026-08-12）/ ⏳ 待办。vault 核心为 C# NativeAOT 独立进程（§8.1），非 Go FFI 承载。

| 层 | 文件 | 改动 | 状态 |
|---|---|---|---|
| vault 核心 | `app/core/vault/`（C# NativeAOT） | vault 文件读写（**crypto `'C'` / slots `'S'` 两种容器**）、AES-256-GCM 加解密、主密钥管理（OS 安全存储 / `file` / slots 槽位表：口令 / 设备 / 恢复 / 口令+设备）、尾部 HMAC verify-before-decrypt、销毁（含 `.bak` + `device.key`）、密钥 mlock | ✅ |
| Dart 注入 | `vault_session_store.dart` / `streaming_store.dart` | 写穿缓存 + vault 会话读写；`loadSecret(id)` 按需单条解密（不再启动预取）；不再读明文 sessionStore | ✅ |
| Dart 登录 | `kugou_api.dart` / netease 登录模块 | 登录成功经 VaultSessionStore 改写 vault（不落 Dart 明文状态） | ✅ |
| Dart 清除 | 设置-安全入口 | 「清除所有本地凭据」接 `VaultProcess.destroy`（删 vault + `.bak` + `device.key` + 份额/锁定状态 + 本地锚点/标记） | ✅ |
| Rust | `downloader/src/`（memsec.rs + lib.rs） | `setKugouSession`/`setNeteaseCookie` 缓冲 MlockSecret（mlock/MADV_DONTDUMP/VirtualLock）+ zeroize | ✅ |
| 迁移 | Dart 启动逻辑 | 旧明文 `netease_session.json` / `streaming_servers.json` → vault 一次性迁移 + 去密覆写（**旧 vault 模式无迁移**） | ✅ |
| 运行时保护 | `MemGuard.cs` + `memsec.rs` + `PlatformGuard.cs` | 主密钥与明文缓冲 mlock/zeroize/munlock；serve 进程 RLIMIT_CORE=0 + PR_SET_DUMPABLE=0 + seccomp-BPF（Linux）/ 缓解策略（Windows）/ RLIMIT_CORE（macOS），best-effort | ✅ |
| 崩溃联动 | `ServeSession.cs` + Dart `VaultProcess` | 会话退出状态校验 → 非预期写 crash 标记 + 主进程 exit(86)；正常 `ok`/主动报错 `fail` 不联动；`VaultCrashGate` 启动警告跳转重置 | ✅ |
| 按需启动与握手 | `PlatformGuard.cs` + `ServeSession.cs` + Dart `VaultProcess` | 按需 spawn/空闲 30s 自退；**父进程身份校验（OS 提供 pid + 可执行文件路径，F3）** + PDEATHSIG/DUMPABLE；握手（H/C 经 stdin，HMAC-SHA256 应答，锚点 T 校验） | ✅ |
| 模式收敛（2026-10） | `VaultFile.cs` + `VaultService.cs` + `SlotCrypto.cs` + `DeviceKeyFile.cs` + `RecoveryCode.cs` + `Program.cs` | crypto（`'C'`）/ slots（`'S'` m1 / m2a / m2b）：槽位表封装 K、尾部 HMAC、KDF 上下限、`init-crypto`/`init-file`/`init-m1`/`init-m2a`/`init-m2b`；移除旧 v1/v2/v3 命令与设备指纹 | ✅ |
| 应用层信任根（F5） | `native_integrity.dart` + `gen_native_manifest.sh` + `sign_native_manifest.sh` + CI | key1 签名清单（`ARCHOERA-NATIVE-MANIFEST.sig1`）运行期验签 + 摘要；vault 二进制 spawn 前校验 | ✅ |
| 解锁失败退避 | `Lockout.cs` + `ShareBundle.cs` | 爆破退避 + 速率限制（§3.7 会话级联动配套）：错误口令/份额缺失/篡改连续失败指数退避 1s→5min，锁定期间连尝试都不做；crypto 模式退避状态内嵌 `master-share`，slots 模式回退明文 `vault.lockout`（已声明残余） | ✅ |

## 5. 风险与权衡

| 风险 | 应对 |
|---|---|
| Linux 无桌面环境（无 Secret Service） | 可选用 `file` 后端（headless）或 slots 模式（自包含，无 keyring 依赖），明确提示；不静默降级 |
| 用户遗忘口令（slots m1/m2a）→ vault 不可解 | m2a 用恢复码兜底；彻底不可恢复时「销毁重建」（重新登录），代价可接受 |
| keyring API 三平台行为差异 | 先 Linux 验证，再 Win/macOS CI 回归 |
| 每请求解密开销 | AES-GCM 微秒级可忽略；Argon2id 仅在解锁时执行一次 |
| 与 downloader-identity 计划交集 | vault 存指纹？不——指纹（§downloader-identity）是非敏感随机值，无需加密；vault 只管登录凭据 |
| mlock 受 RLIMIT_MEMLOCK 限制（默认 8KB 过小） | 启动时 setrlimit 提限，或仅锁关键小区域（主密钥/单条明文缓冲），不锁全进程 |
| PR_SET_DUMPABLE=0 影响调试 | debug 构建豁免，仅 release 启用 |
| 崩溃联动误伤（网络抖动等导致 vault 子进程误判非预期） | 严格区分正常/非预期退出（shutdown 通知先行）；vault 子进程自身加看门狗自检，仅对确定性异常触发 |
| 连带崩溃中断播放 | 安全优先的接受项；仅凭据模块异常触发，播放器自身崩溃不受影响 |
| 按需 spawn 会话开销（进程启动 + 解锁主密钥） | 仅登录/下载注入等低频场景发生，AES-GCM 微秒级，进程启动几十 ms 可接受；不做常驻 |
| 握手密钥经管道传递 | 匿名管道仅父子进程可见（非系统级 IPC），会话密钥一次性防重放；不落盘不回显 |
| 攻击者反复尝试解锁（爆破 vault / OS 安全存储） | 解锁失败指数退避 + 速率限制（挂 §3.7 会话级联动）；高价值凭据口令解锁（Argon2id 天然防 GPU 爆破）；凭据短时效压缩被滥用窗口 |
| 恶意构造 vault 文件（超大/超长条目 → 加载内存耗尽 DoS） | VaultFile.Load 加载上限（VaultLimits：文件 ≤16MB / 条目 ≤10 万 / 单条目 ≤4MB），超限快速拒绝（2026-08-13 演练修复，§8.6） |
| 恶意 KDF 参数（槽位 m/t/p 巨大或极小 → 解锁前内存/CPU DoS / 降级） | 槽位 KDF 参数加载**上下限**（VaultLimits：m∈[8192 KiB, 256 MiB] / t∈[1,16] / p∈[1,8]），解析时快速拒绝，绝不进入 Argon2id 分配（SEC-06 + F1 下界） |
| 多解锁路径增加被攻击面 / 丢失源 | m2a 仅加 1 条高熵恢复码路径（恢复槽）用于防丢失，其余不加；vault 文件不含 deviceSecret |

## 6. 分步落地

> 全部完成（2026-08-12）。实现编号 vault-1 ~ vault-4 与步骤对应；vault 核心为 C# NativeAOT（§8.1 偏差说明）。
> **⚠️ 以下步骤 1–6 描述的是旧 v1/v2/v3 实现（含 2-of-2、`init-password`、设备绑定），现已随 2026-10 重构移除，仅作审计溯源；现行模式见 §3。**

1. **第一步：vault 核心**——C# NativeAOT `archoera-vault`：文件格式（AVLT + AES-256-GCM）+ 密钥管理（OS 安全存储优先）+ **主密钥拆分（2-of-2 协同解密，§3.2.1）** + 加解密 + 销毁 + 密钥 mlock；已验证「磁盘无明文」与「仅 vault 侧份额无法解密」 ✅（= vault-1）
2. **第二步：Dart 接入**——VaultSessionStore 写穿缓存、注入链路改走会话解密、设置页销毁接入、旧明文迁移、StreamingStore.preloadSecrets ✅（= vault-2）
3. **第三步：Rust zeroize + 运行时内存保护**——下载器缓冲 mlock/MADV_DONTDUMP/VirtualLock + zeroize；serve 进程 RLIMIT_CORE=0 + PR_SET_DUMPABLE=0；真实凭据端到端验证 ✅（= vault-3）
4. **第四步：崩溃联动（fail-closed）**——serve 会话 + 退出状态校验、非预期退出写 crash 标记 + 主进程 exit(86)（NO_ABORT 测试豁免）、VaultCrashGate 启动警告跳转重置 ✅（= vault-4）
5. **第五步：按需启动与握手协议**——按需 spawn/空闲 30s 自退、血缘校验（getppid/ParentPid）+ PDEATHSIG/DUMPABLE、握手（H/C 经 stdin + HMAC-SHA256 应答 + 锚点 T）✅（= vault-4，与第四步同批实施）
6. **第六步：口令模式（t9，2026-08-12）**——Argon2id 纯 BCL 实现（RFC 9106 §5.3 向量自检）+ vault v2 口令模式（KDF 参数随文件头）+ `init-password`/口令握手（stdin 传口令，不落 argv）+ 解锁失败指数退避（`Lockout.cs`，锁定期间连尝试都不做）+ Dart `VaultProcess` 口令 API（initPassword/open(password)/mode）✅

## 7. 验证计划

> 状态：✅ 已通过 / ⏳ 待做（Windows/macOS 真机项）。

1. ✅ 磁盘无凭据明文：test.sh「磁盘无明文」+ Dart 测试全盘 grep（vault 文件 + 份额文件均不含明文串）；
2. ✅ 正常流程回归：vault 测试全链路 + 真实凭据端到端（网易 VIP FLAC / 酷狗 flac24bit 解锁，匿名对照被拒）；
3. ✅ 销毁后不可恢复：destroy 删 OS 份额 + vault 文件 + 本地锚点/标记，status 未初始化；
4. ✅ 三平台 keyring：Win DPAPI / macOS Keychain 真机验证；Linux 无头经**生产 `FileStore`**（`ARCHOERA_VAULT_BACKEND=file`）等价路径验证（SEC-19 后不再有测试明文后端）；libsecret 真机待有桌面会话时补验；
5. ✅ `flutter analyze` + `cargo test` + test.sh 全绿（2026-08-12：analyze 无问题、cargo 11 项、flutter 35+ 项、test.sh 12 项）；
6. ⏳ 运行时保护细项：swap 无明文 / core dump 不含敏感区 / 无法经 `/proc/pid/mem` 读取（RLIMIT_CORE=0 已断言，DUMPABLE 尽力保护）；
7. ✅ 崩溃联动：SIGKILL serve 会话 → 父进程感知信号退出 → crash 标记契约（写→消费→删除）✅；**注意**：kill -SEGV 不适用——NativeAOT 接管 SIGSEGV 进入挂起诊断态不退出（§8.4 注意事项）；
8. ✅ 按需启动：会话结束即退（quit）、独立运行被拒（无白名单/白名单不含父进程）、错误握手被拒、锚点不一致拒绝服务（vault 文件被替换 → VaultException）；握手密钥每次会话随机（防重放）；
9. ✅ 协同解密：仅 vault 侧份额无法解密（删 S → 握手 err）；两侧协同可解密；篡改密文被 GCM 认证拦截。
10. ✅ 口令模式（t9）：`selftest` 通过 RFC 9106 §5.3 全部 4 组向量（含 secret/ad 二进制）；init-password 口令走 stdin 不落 argv；正确口令握手 set/get 全链路；错误口令被拒并触发指数退避；锁定期间正确口令也拒绝（连 KDF 都不做）；退避过期后恢复。

## 8. 实施记录与测试（vault-1 ~ vault-4）

> **⚠️ 本节为旧实现（v1/v2/v3 + 2-of-2）的历史记录，仅供审计溯源**；现行模式、命令、销毁与信任根见 §3 / §8.5。
> 2026-10 重构移除：`init`/`init-password`/`init-device`/`switch-mode`/`upgrade-device`/`rebind`/`clear-device-seal`/`set-recovery-password`/`clear-recovery-password`、`DeviceEntropy.cs`/`Fingerprint.cs`、`ARCHOERA_VAULT_PARENT_OK`/`ARCHOERA_VAULT_FINGERPRINT`/`ARCHOERA_VAULT_SECRET_KEY`/`ARCHOERA_VAULT_INSECURE_FILE_STORE`。

### 8.1 vault-1：vault 核心（C# NativeAOT）

- 实现：`app/core/vault/`（`src/Vault.csproj` net9.0 `<PublishAot>true`，产物 `archoera-vault`）；
- CLI（命令走 argv，均非密文；`set` 密文负载经 stdin 首行）：
  - `ping` / `init <dataDir> → ok <b64T>`（返回会话锚点 T）/ `status <dataDir> → ok {"initialized":true|false}` / `destroy <dataDir> → ok`；
  - **`set`/`get`/`delete` 独立子命令已删除**——凭据访问只经 `serve` 会话（杜绝绕过父进程身份校验的独立调用路径）；
- 存储：`credentials.vault`（AVLT magic + AES-256-GCM，每条目独立 nonce/salt）+ OS 安全存储份额；
- **2-of-2 协同解密**：主密钥 K = K_vault（vault 文件头 32B）⊕ S（OS 安全存储）；份额任一缺失即 fail-closed；
- 平台存储：`SecretStores.cs`（DPAPI / Keychain / libsecret / `FileStore` 文件密钥模式）；`FileStore` 既是生产 LEGACY 模式，也用作无头测试后端（`ARCHOERA_VAULT_BACKEND=file`，SEC-19 删除测试明文后端后）；**构建标记**：`--version` 输出构建标记（生产 `ARCHOERA-VAULT-PROD-*` / 测试 `TEST-*`），Dart `VaultProcess._verifyProduction` 默认路径加载前校验 PROD 标记，测试/被替换二进制 fail-closed 拒绝服务（**定位=防误用测试构建**；应用层完整性现由 **key1 签名清单**承接，见 §8.5）；
- 内存：`MemGuard.cs` LockedBuffer（mlock → 用后 zeroize + munlock）。

### 8.2 vault-2：Dart 接入

- `VaultSessionStore`：写穿缓存（get/save/clear 同步返回，vault 持久化串行队列异步执行）+ 旧明文 `netease_session.json` 首启一次性迁移后覆写删除；
- `streaming_servers` 纳入 vault（uid=`streaming:<serverId>`，配置 JSON 只留非敏感字段）；
- 降级语义：vault 不可用 → 仅内存保留登录态（不静默降级为明文持久化）。
- **已知接受项（SEC-03）**：`main.dart` 在 `VaultSessionStore.initialize()` 后 `await StreamingStore.preloadSecrets()`（§8.4）——**启动即解密全部流媒体凭据并以写穿缓存常驻 Dart 堆**，作为同步 `load()` 的数据源。Dart 字符串不可 zeroize、不受 §3.6 mlock 保护；缓解为 Linux release 下主进程 `PR_SET_DUMPABLE=0` + `RLIMIT_CORE=0`（不覆盖同用户读 `/proc/<pid>/mem`）。定性见 §3.3 与 [security-review SEC-03](security-review-2026-10-11.md)。

### 8.3 vault-3：Rust 下载器内存保护

- `memsec.rs`：`MlockSecret`（Linux/macOS mlock + MADV_DONTDUMP / Windows VirtualLock）+ zeroize；
- `KugouState.userid/token` 与 `netease_cookie` 迁入受保护缓冲；FFI setter 用 `Zeroizing` 保护中间副本；
- 已用真实凭据端到端验证（网易 VIP FLAC + 酷狗 flac24bit 解锁；匿名对照被拒）。

### 8.4 vault-4：崩溃联动（§3.7）+ 按需启动与握手（§3.8）

**C# 侧**：

- `PlatformGuard.cs`：
  - Linux：OS 侧父进程身份校验（`/proc/<ppid>/exe`）+ `PR_SET_PDEATHSIG(SIGTERM)` + `RLIMIT_CORE=0` + `PR_SET_DUMPABLE=0` + **seccomp-BPF denylist**（拒 ptrace/进程内存/网络 AF_INET·AF_INET6 socket/execve/bpf/内核模块/命名空间/io_uring → `SECCOMP_RET_KILL_PROCESS`；AF_UNIX 放行）；
  - macOS：OS 侧父进程身份校验（`proc_pidpath`）+ `RLIMIT_CORE=0`（无 seccomp 等价物）；Windows：OS 侧父进程身份校验（`NtQueryInformationProcess` + `QueryFullProcessImageNameW`）+ `SetProcessMitigationPolicy`（ACG/CIG/ExtensionPointDisable/StrictHandle/CFG/ImageLoad，best-effort）+ 父死检测（OpenProcess/GetExitCodeProcess）；
  - **父进程身份校验（F3，2026-10）**：由 OS 提供父进程 pid + 可执行文件路径（Linux `/proc/<ppid>/exe`、macOS `proc_pidpath`、Windows `QueryFullProcessImageNameW`），与「由 vault 位置推导的预期主程序路径」比对；**不再读取 `ARCHOERA_VAULT_PARENT_OK`（已完全移除）**。同用户攻击者可在预期路径放置自造二进制，**不防同用户**，见 §3.8 定位；
- `ServeSession.cs`（stdin/stdout 行协议，UTF-8）：
  ```
  主进程 → vault:    handshake <b64H> <b64C>        H=32B 随机会话密钥，C=16B challenge
  vault → 主进程:    ok handshake <b64T> <b64mac> <marker>   T=16B 锚点，mac=HMAC-SHA256(H, C)，
                                            marker=BuildInfo.Marker（PROD/TEST 构建版本指纹）
  主进程 → vault:    get <uid> | set <uid> | delete <uid> | status | destroy | quit
  vault → 主进程:    ok <payload> | err <message>   （set 的 base64 负载走下一行）
  ```
  - **握手前置**：握手完成前不加载/不解密任何凭据（首个凭据访问发生在解锁主密钥的握手应答时刻）；
  - 双因子：进程血缘 + 主密钥持有（解锁成功 + 锚点回读）；会话密钥一次性防重放；
  - **握手版本指纹**：应答尾部携带 `BuildInfo.Marker`，主进程据此在协议内识别 vault 构建（默认路径须 PROD，见 Dart 侧）；**仅防误用测试构建，非二进制完整性防护**（定性见 §3.8）；
  - 空闲 30s 自退 / 握手超时 10s / 父死自退（事件驱动，无轮询）；
- `Program.cs`：`init` 返回锚点 `ok <b64T>`；错误输出 `err <message>` 且退出码 1（信息不含明文/密文片段）。

**Dart 侧**（`VaultProcess` 会话模式重写）：

- 每次操作 spawn `serve` → 握手（HMAC 自算比对 + **构建 marker 校验** + 锚点校验）→ 命令 → `quit` → 退出状态校验 → 写标记；
- **握手版本指纹（marker 校验）**：解析应答第 5 字段 `BuildInfo.Marker`——默认路径解析的 vault 必须为 PROD 标记；**缺失或非 PROD（TEST 构建 / 被替换二进制）→ 杀进程 + 删除默认路径副本 + 失效缓存 + 置 `versionFatal`（fail-closed）**；env 显式指定（测试/CI 信任边界）跳过 PROD 校验但 marker 存在性仍校验；
- `VaultVersionException` + `VaultVersionGate`：版本异常触发时置 `VaultProcess.versionFatal`，UI 顶层 gate 全屏拦截**仅允许退出**（不提供销毁/重试等继续操作）；
- 锚点 `$dataDir/vault.auth`：首会话返回保存，后续会话必须一致——不一致 = vault 文件被替换 → 拒绝服务。
  **勿高估（SEC-05）**：`vault.auth` 与 `credentials.vault` 同为 `dataDir` 下普通文件、权限未定义，
  **同用户攻击者可同时替换两者**使锚点校验失效；这些文件**不构成对同用户攻击者的防线**（只防不一致替换/误操作）。
  **退避状态已加固（2026-10-12）**：退避状态现**内嵌于 `master-share` 份额槽位**（`ShareBundle`），
  删除/伪造明文 `vault.lockout` 不再重置在线爆破节流（单槽后端删份额即砖化 vault）；口令 / 多封装模式因
  份额由口令或设备熵现场派生、不入库，仍回退明文 `vault.lockout`，属已声明残余。见
  [security-review SEC-05](security-review-2026-10-11.md)；
- **崩溃联动标记** `$dataDir/vault.marker`：正常收尾 `ok` / 主动报错 `fail`（不联动）/ 非预期退出（信号终止/挂起/EOF）`crash` → 主进程 `exit(86)` fail-closed（`ARCHOERA_VAULT_NO_ABORT=1` 测试豁免，仅写标记）。
  **勿高估（SEC-05，2026-10-12 更正）**：`exit(86)` 只由**真实异常退出路径**（`_record`→`_abort`）触发；
  `consumeCrashMarker` 读到**伪造**的 `crash` 不会 `exit(86)`，仅在下一次启动弹出**可关闭**的崩溃提示，
  伪造 `ok` 则可能掩盖一次真实崩溃的提示。该标记只是「崩溃可感知性提示」，**不是对同用户攻击者的防线**；
- `VaultCrashGate`：启动首帧消费 crash 标记 → 显著警告（「销毁并重建」/「知道了」跳转）；
- `main.dart`：`VaultSessionStore.initialize()` 后 `await StreamingStore.preloadSecrets()`（同步 `load()` 的凭据来源）。

**实施注意事项**：

- **NativeAOT 运行时接管 SIGSEGV**：收到 SIGSEGV 进入挂起诊断态、进程不退出（父进程 wait 超时）——崩溃联动测试须用 SIGKILL（正常信号退出 -9 可被感知）；§7-7 验证项的 kill -SEGV 用例改为 SIGKILL；
- 测试环境变量：测试二进制（`archoera-vault-test`）与生产唯一区别是构建标记（TEST）；存储后端用**生产 `FileStore`**（`ARCHOERA_VAULT_BACKEND=file`，SEC-19 后无明文后门）；crash 用例 `ARCHOERA_VAULT_NO_ABORT=1`。

### 8.5 测试与回归（2026-08-12 全绿）

| 套件 | 覆盖 | 结果 |
|---|---|---|
| `app/core/vault/test.sh`（18 项） | init 锚点 / serve 会话全链路（HMAC 独立验证 + **握手 marker 断言**）/ 独立运行拒绝 ×2 / 错误握手 ×2 / 磁盘无明文 / 缺 S fail-closed / GCM 篡改拦截 / 信号终止可感知 / destroy / **selftest（RFC 9106 向量）** / **口令模式全链路（init-password→口令握手→set/get/quit）** / **错误口令锁定退避 + 锁定期间拒绝 + 退避后恢复** | ✅ |
| `flutter test`（45 项） | 含 `vault_process_v4_test.dart`（中文往返 + marker=ok / 锚点不一致拒绝服务 / 信号终止感知 + crash 标记契约 + **TEST marker 字段断言**）、`vault_session_store_test.dart` 新增**口令模式用例**（initPassword + mode=password + 口令握手 set/get + 错误口令被拒）、既有 vault 测试适配 async API | ✅ |
| `cargo test`（11 项） | 下载器加解密往返 | ✅ |
| `dart analyze lib test` | 无问题 | ✅ |

待办：Windows / macOS 平台护栏真机验证（父进程身份校验、seccomp/ACG-CIG、RLIMIT_CORE）、三平台 keyring 验证、Dart 设置页新模式的交互（m1/m2a/m2b 初始化与解锁 UI）。
**信任根：应用层 key1 签名清单（F5），OS 签名不推进（2026-10 定稿）**——原计划「Windows Authenticode 签名 / macOS 公证」因成本与步骤不可得，**不再作为待办**。
**已落地**：构建期对 bundled `native/` 全部文件（FFI 库、vault 二进制、主程序、AOT `libapp.so`）生成 SHA-256 清单
`ARCHOERA-NATIVE-MANIFEST.txt`，由 **key1（ECDSA P-256/SHA-256）签为 `ARCHOERA-NATIVE-MANIFEST.sig1`**；
运行期 `NativeIntegrity` 以内嵌公钥**先验签、再按 basename 逐文件比对摘要**（打包态 fail-closed，签名不合法立即拒绝；开发态/无清单跳过并警告），
vault 二进制在 spawn 前亦经该校验（`VaultProcess._resolveBinary`）。CI 在 release 作业内对**可被 release 控制的目录型产物**注入签名清单
（macOS / Windows tar、Linux 原始 bundle、Windows 便携 zip）；deb/rpm/AppImage/flatpak/pkg.tar.zst/nixos 依赖**包管理器签名**，Inno `.exe` 依赖**外层 `.sig1`**。
**残余（如实）**：验证逻辑本身在可被替换的进程里，**主程序自身未被校验**（进程无法自证），Dart 亦无法拦截原生传递依赖（FFmpeg/转码器）的 `dlopen`——
故**替换主程序 / 同用户运行期注入主程序不可防**，属威胁模型硬上限，详见 [supply-chain.md §2](supply-chain.md) 与 [vault-security-notes.md](vault-security-notes.md)。

### 8.6 攻击面演练与加固（2026-08-13）

恶意 vault 数据库替换演练（对每个变体 serve 会话逐个验证，备份→替换→握手→判定→恢复）：

| 恶意变体 | 攻击意图 | 结果 |
|---|---|---|
| 随机字节 / 截断真库 | 解析器鲁棒性 | ✅ magic 不符 / 流越界 → `err` 拒绝 |
| 篡改真库 1 字节 | GCM 认证绕过 | ✅ 认证失败拒绝 + 触发锁定退避 |
| 条目数 2³¹ / 单条目密文 2GB | 循环爆炸 / 内存耗尽 DoS | ✅ 修复后「条目数/长度异常」拒绝 |
| **1GB 稀疏库（合法头 + 巨大条目数）** | **加载内存耗尽 DoS** | ✅ **修复后**「文件过大」拒绝 |
| uid=`../../tmp/pwned`（路径遍历） | 越界写文件 | ✅ 锚点校验拒绝（vault 接受补建锚点 → Dart vault.auth 比对不一致拒绝）；uid 仅作存储标识，无文件路径副作用 |
| 非法 UTF-8 uid | 解码异常 | ✅ 无害 |

**发现并修复 DoS 漏洞**：修复前 `VaultFile.Load` 对 `count`/`ctLen` 无上限，1GB 稀疏库被完整加载为 ~1677 万条 entry（内存 ~1.5GB），应用启动即被拖垮。新增 `VaultLimits` 加载上限（`VaultFile.cs`）：文件 ≤16MB / 条目 ≤10 万 / 单条目 ≤4MB（正常库仅 KB 级，余量充足），超限抛 `InvalidDataException` 快速拒绝，不分配/不循环。回归：vault `test.sh` + flutter vault 测试全绿，正常库 serve 解密不受影响。

**补充修复 KDF 参数 DoS（SEC-06，2026-10-12）**：上表仅限条目数/长度/文件大小，未覆盖 v2/v3 头部与封装块中的 Argon2id 参数 `m/t/p`（u32，且不受文件大小约束）——恶意构造 `m≈2^32` 会在**任何认证之前**触发巨量内存分配。现 `VaultFile` 统一经 `VaultLimits.ValidateKdf` 解析：`m ≤256 MiB / t ≤16 / p ≤8`（正常档 64 MiB/3/1，自检向量最大 m=65536/p=4，余量充足），越界即抛 `InvalidDataException` 快速拒绝；`ReadHeader`（握手前）与 `Load`（解锁）两条路径均覆盖，`Argon2id.Derive` 另设同上限作纵深防御。关于头部认证：KDF 参数未单独认证，但参数被篡改只会派生错误的 S（→ 错误 K → 条目 AEAD 认证失败），不泄露数据，DoS 面由上述上限消除。回归：`test.sh` 第 21 项（超大 m/t/p 快速拒绝 + 合规参数正常解锁）。

---

