# 凭据保险库规划

> 状态：**已实施（vault-1 ~ vault-4 + 第六步口令模式全部完成，2026-08-12）** · 规划稿初稿 2026-08-12
> 定位：把本地凭据（流媒体服务器密码、网易/酷狗 session）从「明文落盘 + 进程存活期明文」改造为
> **静态加密存储（vault）+ 按需流式解密 + 运行时内存保护 + 一键销毁**，防磁盘泄露与「销毁即失效」。
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
5. **信任根边界（主程序进程）**：vault 的全部防线（血缘校验、握手 marker 校验、fail-closed）都建立在「主进程可信」的前提上。攻击者**同时替换主程序（Dart 可执行 / FFI 库）** 或**在主进程内嵌主动联网上传程序段**时——FFI 库运行在主进程内，主进程本身即 vault 的合法握手对象，vault 无从区分被篡改的主程序，会在明文窗口被截获凭据并外传。此类威胁（进程注入 / 信任根攻破）**超出应用层能力**，由 OS 信任链承担：Windows Authenticode 签名 / macOS 公证 / 安装包完整性校验（待办见 §8.5）。

---

## 2. 目标

1. 凭据**静态加密**：磁盘上只有密文，无任何明文副本；
2. **可销毁性**：销毁 vault 文件 = 本地 token 永久失效（明文从未落盘，无法恢复）；
3. **按需流式解密**：注入/请求前短时解密单条凭据，用后即弃，缩短明文生命周期；
4. 主密钥安全：优先 OS 安全存储（DPAPI/Keychain/libsecret），口令派生（Argon2id）为可选高级项；
5. 与现有「清除凭据」入口对齐，不引入第二套机制（vault 核心实施为 C# NativeAOT，桌面端 Go 凭据加解密 FFI 保留）；
6. **运行时内存保护**：主密钥与短时明文缓冲 mlock 禁 swap、MADV_DONTDUMP 禁 dump 泄露、release 启动禁调试读取（Linux 机制三平台映射，§3.6）；
7. **崩溃联动（fail-closed）**：凭据模块非预期退出 → 连带主进程终止，内存随系统回收；下次启动显著警告（§3.7）；
8. **按需启动与握手协议**：凭据模块不常驻、按需会话化启动，拒绝独立/脱离主程序的非法启动，会话经握手认证（§3.8）；
9. **主密钥拆分（2-of-2 协同解密）**：主密钥拆为两份份额缺一不可（vault 侧 + 用户口令/系统授权侧），攻击者须同时攻破两侧，任何单点泄露不足以解密（§3.2.1）。

---

## 3. 方案设计

### 3.1 Vault 文件（静态存储）

```
app_config/
├── credentials.vault        # 全部凭据密文（AES-256-GCM 或 XChaCha20-Poly1305）
└── vault.meta               # 非敏感元数据：版本、KDF 参数、nonce 索引（密钥不在此）
```

- 格式：`magic(8B) | version | KDF 参数 | 条目表（每条: platform_id | salt | nonce | 密文 | 关联 uid）`；
- 每条凭据独立 nonce/salt：支持**单条更新与删除**（重写整个 vault 或追加式日志+压缩）；
- 统一承载：流媒体服务器密码、本地 Subsonic 账号、网易/酷狗 session（对齐「清除所有本地凭据」的覆盖面）。

### 3.2 主密钥管理（二选一）

| 方案 | 机制 | 体验 | 安全 |
|---|---|---|---|
| **OS 安全存储（推荐默认）** | Windows DPAPI（CryptProtectData）/ macOS Keychain（kSecClassGenericPassword）/ Linux libsecret（Secret Service） | 用户无感，随系统账户解锁 | 密钥由 OS 管，不落盘；同用户攻击者仍可经 API 取（边界 §1.2） |
| **用户口令派生（可选高级）** | Argon2id（memory-hard）派生主密钥，只存 KDF 参数，解锁时输入口令 | 首次使用/启动时输入一次 | 最强：拿到 vault + meta 仍需口令；遗忘口令则 vault 不可解（提供销毁重建） |

- 默认走 OS 安全存储，与「强迫症」设置区风格一致，口令派生做高级开关；
- **开源约束下的定位（§1.2-4）**：OS 安全存储**不降级**——仍是纵深关键一层（系统级密钥保护 + 可启用授权策略/凭据绑定/TPM）；同用户恶意进程威胁由**口令派生（Argon2id）+ 解锁失败退避 + 凭据短时效**叠加防御，高价值凭据建议口令解锁模式；
- **Linux 无桌面环境（无 Secret Service）降级**：明确提示降级为口令派生或禁用登录态持久化。

### 3.2.1 主密钥拆分（2-of-2 协同解密）

把「主密钥整体存于一处」升级为「两份份额缺一不可」——攻击者须**同时攻破两侧**，任何单点泄露（仅 vault 文件 / 仅源码 / 仅口令哈希）都不足以解密：

```
加密时：随机主密钥 K → 随机份额 S（熵源：口令派生/系统授权）
        K_vault = K ⊕ S 存入 vault（随 OS 安全存储保护）
        K_host  = S 锚定于「用户口令派生」或「系统授权」
解密时：vault 会话进程持 K_vault（经 OS 安全存储解锁）
        主进程经口令/系统授权取回 S → 协同 K = K_vault ⊕ S → 解密
```

关键约束：

- **S 的不可预知性必须锚定在攻击者拿不到的地方**（用户口令记忆 / 系统授权凭据）——不能只是「主进程本地随机生成后保存」，否则逆向者照源码同样能取得；
- 攻击者：只拿 vault + 解锁 OS 安全存储 → 缺 S 解不开；逆向源码模拟主进程 → 缺 S 的熵源解不开；
- 效果：本地解密从「单点防线」升级为「双因子」——需要 vault 侧（系统账户边界）与用户侧（口令/授权）同时在场。

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
- **Dart 侧**：仅注入那一行持有明文，不进状态对象、不落日志（日志长度掩码保留）；实施为 VaultSessionStore / StreamingStore 写穿缓存 + 启动预取（§8.2）。

### 3.4 销毁流程（可销毁性）

- **全量销毁**（设置-安全-清除所有本地凭据，已有入口）：删除 `credentials.vault` + 清进程内已加载凭据 + 调平台登出接口 + 可选重生成主密钥；
- **单凭据登出**：重写 vault（去除该条）+ 清内存缓存；
- 销毁后旧密文不可恢复（明文从未落盘）——实现「变相销毁 token」，即使平台侧 token 仍有效，本地已无可用密文。

### 3.5 迁移

- 首启检测到旧明文 sessionStore：一次性加密迁移进 vault，随后**彻底删除明文存储**（含备份路径）；
- 迁移失败（如 keyring 不可用）→ 保留明文并显著警示，不静默降级。

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
主进程：生成随机会话密钥 H + challenge C
        → spawn vault（argv 仅传管道句柄，H/C 经管道下发，不回显不落盘）
vault：  校验父进程 → 解锁主密钥（OS 安全存储，§3.2）
        → 应答 = HMAC-SHA256(H, C) + 构建标记 marker → 经管道回传
主进程：验证应答（HMAC + 锚点 + marker）→ 建立受信会话 → 会话结束即退
```

- 双因子：**进程血缘**（父进程校验 + PDEATHSIG）与**主密钥持有**（伪造主进程无法从 OS 安全存储解锁主密钥）；
- **握手版本指纹（marker）**：握手应答尾部携带 `BuildInfo.Marker`（PROD/TEST 构建标记）。主进程据此在**协议内**直接校验 vault 版本/构建——默认路径解析的 vault 必须为 PROD：**缺失或非 PROD（如被替换为携带 `ARCHOERA_VAULT_INSECURE_FILE_STORE` 显式启动指令的测试二进制）→ 杀进程 + 删除默认路径副本 + 拒绝解密 + 版本异常 fatal 态（UI 仅允许退出，fail-closed）**。这是二进制替换防护的第二道（协议内）防线，防止仅绕过加载前 `--version` 校验的二次侵入；
- **握手前置能力**：vault 在握手完成前**不加载/不解密任何凭据**——未完成握手即崩溃/被终止，也从未产生过明文；主进程会话期间保持管道读端监听 + waitpid，异常退出（EOF）即不信任结果并触发 §3.7 fail-closed；
- 独立运行 vault：无管道、无 H/C → 直接拒绝服务；
- 每次会话的握手密钥一次性，防重放；会话期间所有命令仅经该管道，vault 不响应其他来源；
- **定位（开源约束 §1.2-4）**：握手防的是「无主进程上下文的独立工具滥用与自动化」，**不承诺防「按源码重实现的攻击者」**——该威胁由口令派生/平台侧防线承担。

通信模型（全链路事件驱动，无轮询）：

- vault 等待命令：阻塞 `read(stdin)`，无命令即挂起；
- 空闲超时：`poll/select` 带 timeout 的**单次阻塞**，超时自退（非定时巡检）；
- 主进程感知退出：管道读端 **EOF** + `SIGCHLD`/`waitpid`（Go goroutine + `cmd.Wait()` 阻塞），事件到达才处理，主循环不被占用；
- 命令下发：阻塞写管道；
- 与引擎事件推送计划同思路（能被动感知就不主动询问，全程零忙轮询）。

三平台映射：血缘校验 Linux/macOS `getppid` + Windows ParentPid；父死联动 Linux `PR_SET_PDEATHSIG` / macOS `posix_spawn` 变体 / Windows Job Object（kill-on-close）；匿名管道三平台均支持。

---

## 4. 改动点清单

> 状态列：✅ 已完成（2026-08-12）/ ⏳ 待办。vault 核心为 C# NativeAOT 独立进程（§8.1），非 Go FFI 承载。

| 层 | 文件 | 改动 | 状态 |
|---|---|---|---|
| vault 核心 | `app/core/vault/`（C# NativeAOT） | vault 文件读写、AES-GCM 加解密、主密钥管理（DPAPI/Keychain/libsecret + **2-of-2 拆分 §3.2.1**）、销毁、密钥 mlock | ✅ |
| Dart 注入 | `vault_session_store.dart` / `streaming_store.dart` | 写穿缓存 + vault 会话读写；注入前短时解密即弃；不再读明文 sessionStore | ✅ |
| Dart 登录 | `kugou_api.dart` / netease 登录模块 | 登录成功经 VaultSessionStore 改写 vault（不落 Dart 明文状态） | ✅ |
| Dart 清除 | 设置-安全入口 | 「清除所有本地凭据」接 `VaultProcess.destroy`（删 OS 份额 + vault 文件 + 本地锚点/标记） | ✅ |
| Rust | `downloader/src/`（memsec.rs + lib.rs） | `setKugouSession`/`setNeteaseCookie` 缓冲 MlockSecret（mlock/MADV_DONTDUMP/VirtualLock）+ zeroize | ✅ |
| 迁移 | Dart 启动逻辑 | 旧明文 `netease_session.json` / `streaming_servers.json` → vault 一次性迁移 + 去密覆写 | ✅ |
| 运行时保护 | `MemGuard.cs` + `memsec.rs` + `PlatformGuard.cs` | 主密钥与明文缓冲 mlock/zeroize/munlock；serve 进程 RLIMIT_CORE=0 + PR_SET_DUMPABLE=0（Linux，release 语义） | ✅ |
| 崩溃联动 | `ServeSession.cs` + Dart `VaultProcess` | 会话退出状态校验 → 非预期写 crash 标记 + 主进程 exit(86)；正常 `ok`/主动报错 `fail` 不联动；`VaultCrashGate` 启动警告跳转重置 | ✅ |
| 按需启动与握手 | `PlatformGuard.cs` + `ServeSession.cs` + Dart `VaultProcess` | 按需 spawn/空闲 30s 自退；血缘校验（getppid/ParentPid）+ PDEATHSIG/DUMPABLE；握手（H/C 经 stdin，HMAC-SHA256 应答，锚点 T 校验） | ✅ |
| 口令派生（高级项） | `Argon2id.cs` + `VaultFile.cs`(v2) + `VaultService` + `ServeSession` + Dart `VaultProcess` | Argon2id 口令解锁模式（§3.2 可选开关）：纯 BCL 实现（RFC 9106 自检向量）+ init-password/口令握手（stdin 传口令，不落 argv）+ status mode | ✅ |
| 解锁失败退避 | `Lockout.cs` | 爆破退避 + 速率限制（§3.7 会话级联动配套）：错误口令/份额缺失/篡改连续失败指数退避 1s→5min，锁定期间连尝试都不做 | ✅ |

## 5. 风险与权衡

| 风险 | 应对 |
|---|---|
| Linux 无桌面环境（无 Secret Service） | 降级口令派生或禁用持久化，明确提示；不静默降级 |
| 用户遗忘口令 → vault 不可解 | 提供「销毁重建」（重新登录），代价可接受 |
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
| 协同解密使数据可用性依赖两侧同时在场 | 份额任一丢失 → 走「销毁重建」路径（与遗忘口令同代价）；口令侧份额熵源锚定记忆/系统授权，不额外引入易失存储 |

## 6. 分步落地

> 全部完成（2026-08-12）。实现编号 vault-1 ~ vault-4 与步骤对应；vault 核心为 C# NativeAOT（§8.1 偏差说明）。

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
4. ⏳ 三平台 keyring：Win DPAPI / macOS Keychain 真机验证；Linux libsecret 经 InsecureFileStore 等价路径（无头环境）验证；
5. ✅ `flutter analyze` + `cargo test` + test.sh 全绿（2026-08-12：analyze 无问题、cargo 11 项、flutter 35+ 项、test.sh 12 项）；
6. ⏳ 运行时保护细项：swap 无明文 / core dump 不含敏感区 / 无法经 `/proc/pid/mem` 读取（RLIMIT_CORE=0 已断言，DUMPABLE 尽力保护）；
7. ✅ 崩溃联动：SIGKILL serve 会话 → 父进程感知信号退出 → crash 标记契约（写→消费→删除）✅；**注意**：kill -SEGV 不适用——NativeAOT 接管 SIGSEGV 进入挂起诊断态不退出（§8.4 注意事项）；
8. ✅ 按需启动：会话结束即退（quit）、独立运行被拒（无白名单/白名单不含父进程）、错误握手被拒、锚点不一致拒绝服务（vault 文件被替换 → VaultException）；握手密钥每次会话随机（防重放）；
9. ✅ 协同解密：仅 vault 侧份额无法解密（删 S → 握手 err）；两侧协同可解密；篡改密文被 GCM 认证拦截。
10. ✅ 口令模式（t9）：`selftest` 通过 RFC 9106 §5.3 全部 4 组向量（含 secret/ad 二进制）；init-password 口令走 stdin 不落 argv；正确口令握手 set/get 全链路；错误口令被拒并触发指数退避；锁定期间正确口令也拒绝（连 KDF 都不做）；退避过期后恢复。

## 8. 实施记录与测试（vault-1 ~ vault-4）

### 8.1 vault-1：vault 核心（C# NativeAOT）

- 实现：`app/core/vault/`（`src/Vault.csproj` net9.0 `<PublishAot>true`，产物 `archoera-vault`）；
- CLI（命令走 argv，均非密文；`set` 密文负载经 stdin 首行）：
  - `ping` / `init <dataDir> → ok <b64T>`（返回会话锚点 T）/ `status <dataDir> → ok {"initialized":true|false}` / `destroy <dataDir> → ok`；
  - **`set`/`get`/`delete` 独立子命令已删除**——凭据访问只经 `serve` 会话（杜绝绕过血缘校验的独立调用路径）；
- 存储：`credentials.vault`（AVLT magic + AES-256-GCM，每条目独立 nonce/salt）+ OS 安全存储份额；
- **2-of-2 协同解密**：主密钥 K = K_vault（vault 文件头 32B）⊕ S（OS 安全存储）；份额任一缺失即 fail-closed；
- 平台存储：`SecretStores.cs`（DPAPI / Keychain / libsecret / `InsecureFileStore` 测试明文，`#if VAULT_TESTING` 条件编译）；测试明文存储**仅编译进测试二进制** `build-test.sh` 产物 `archoera-vault-test`（CI/无头测试用），生产 `build.sh` 产物 `archoera-vault` 不含该逻辑——测试后门不进入发布产物；**二进制替换防护**：`--version` 输出构建标记（生产 `ARCHOERA-VAULT-PROD-*` / 测试 `TEST-*`），Dart `VaultProcess._verifyProduction` 默认路径加载前校验 PROD 标记，测试/被替换二进制 fail-closed 拒绝服务；
- 内存：`MemGuard.cs` LockedBuffer（mlock → 用后 zeroize + munlock）。

### 8.2 vault-2：Dart 接入

- `VaultSessionStore`：写穿缓存（get/save/clear 同步返回，vault 持久化串行队列异步执行）+ 旧明文 `netease_session.json` 首启一次性迁移后覆写删除；
- `streaming_servers` 纳入 vault（uid=`streaming:<serverId>`，配置 JSON 只留非敏感字段）；
- 降级语义：vault 不可用 → 仅内存保留登录态（不静默降级为明文持久化）。

### 8.3 vault-3：Rust 下载器内存保护

- `memsec.rs`：`MlockSecret`（Linux/macOS mlock + MADV_DONTDUMP / Windows VirtualLock）+ zeroize；
- `KugouState.userid/token` 与 `netease_cookie` 迁入受保护缓冲；FFI setter 用 `Zeroizing` 保护中间副本；
- 已用真实凭据端到端验证（网易 VIP FLAC + 酷狗 flac24bit 解锁；匿名对照被拒）。

### 8.4 vault-4：崩溃联动（§3.7）+ 按需启动与握手（§3.8）

**C# 侧**：

- `PlatformGuard.cs`：
  - Linux：`getppid` 血缘 + `/proc/<ppid>/comm` 白名单 + `PR_SET_PDEATHSIG(SIGTERM)` + `RLIMIT_CORE=0` + `PR_SET_DUMPABLE=0`；
  - macOS：血缘（proc_pidpath）+ `RLIMIT_CORE=0`；Windows：ParentPid（NtQueryInformationProcess）+ 父死检测（OpenProcess/GetExitCodeProcess）；
  - 白名单由主进程经环境变量 `ARCHOERA_VAULT_PARENT_OK`（逗号分隔可执行名）注入；无白名单 / 父进程不在白名单 → 拒绝独立运行；
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
  - **握手版本指纹**：应答尾部携带 `BuildInfo.Marker`，主进程据此在协议内校验 vault 构建（默认路径须 PROD，见 Dart 侧）；
  - 空闲 30s 自退 / 握手超时 10s / 父死自退（事件驱动，无轮询）；
- `Program.cs`：`init` 返回锚点 `ok <b64T>`；错误输出 `err <message>` 且退出码 1（信息不含明文/密文片段）。

**Dart 侧**（`VaultProcess` 会话模式重写）：

- 每次操作 spawn `serve` → 握手（HMAC 自算比对 + **构建 marker 校验** + 锚点校验）→ 命令 → `quit` → 退出状态校验 → 写标记；
- **握手版本指纹（marker 校验）**：解析应答第 5 字段 `BuildInfo.Marker`——默认路径解析的 vault 必须为 PROD 标记；**缺失或非 PROD（测试/被替换二进制，携带 `ARCHOERA_VAULT_INSECURE_FILE_STORE` 显式启动指令）→ 杀进程 + 删除默认路径副本 + 失效缓存 + 置 `versionFatal`（fail-closed）**；env 显式指定（测试/CI 信任边界）跳过 PROD 校验但 marker 存在性仍校验；
- `VaultVersionException` + `VaultVersionGate`：版本异常触发时置 `VaultProcess.versionFatal`，UI 顶层 gate 全屏拦截**仅允许退出**（不提供销毁/重试等继续操作）；
- 锚点 `$dataDir/vault.auth`：首会话返回保存，后续会话必须一致——不一致 = vault 文件被替换 → 拒绝服务；
- **崩溃联动标记** `$dataDir/vault.marker`：正常收尾 `ok` / 主动报错 `fail`（不联动）/ 非预期退出（信号终止/挂起/EOF）`crash` → 主进程 `exit(86)` fail-closed（`ARCHOERA_VAULT_NO_ABORT=1` 测试豁免，仅写标记）；
- `VaultCrashGate`：启动首帧消费 crash 标记 → 显著警告（「销毁并重建」/「知道了」跳转）；
- `main.dart`：`VaultSessionStore.initialize()` 后 `await StreamingStore.preloadSecrets()`（同步 `load()` 的凭据来源）。

**实施注意事项**：

- **NativeAOT 运行时接管 SIGSEGV**：收到 SIGSEGV 进入挂起诊断态、进程不退出（父进程 wait 超时）——崩溃联动测试须用 SIGKILL（正常信号退出 -9 可被感知）；§7-7 验证项的 kill -SEGV 用例改为 SIGKILL；
- 测试环境变量：测试二进制（`archoera-vault-test`）内 `ARCHOERA_VAULT_INSECURE_FILE_STORE=1`（条件编译测试明文存储）；crash 用例 `ARCHOERA_VAULT_NO_ABORT=1`。

### 8.5 测试与回归（2026-08-12 全绿）

| 套件 | 覆盖 | 结果 |
|---|---|---|
| `app/core/vault/test.sh`（18 项） | init 锚点 / serve 会话全链路（HMAC 独立验证 + **握手 marker 断言**）/ 独立运行拒绝 ×2 / 错误握手 ×2 / 磁盘无明文 / 缺 S fail-closed / GCM 篡改拦截 / 信号终止可感知 / destroy / **selftest（RFC 9106 向量）** / **口令模式全链路（init-password→口令握手→set/get/quit）** / **错误口令锁定退避 + 锁定期间拒绝 + 退避后恢复** | ✅ |
| `flutter test`（45 项） | 含 `vault_process_v4_test.dart`（中文往返 + marker=ok / 锚点不一致拒绝服务 / 信号终止感知 + crash 标记契约 + **TEST marker 字段断言**）、`vault_session_store_test.dart` 新增**口令模式用例**（initPassword + mode=password + 口令握手 set/get + 错误口令被拒）、既有 vault 测试适配 async API | ✅ |
| `cargo test`（11 项） | 下载器加解密往返 | ✅ |
| `dart analyze lib test` | 无问题 | ✅ |

待办：Windows / macOS 平台护栏真机验证（血缘校验、PDEATHSIG/Job Object、RLIMIT_CORE）、三平台 keyring 验证、Dart 设置页口令模式 UI（initPassword 入口 + 口令解锁交互，底层 API 已就绪）、**OS 信任链加固（§1.2-5 信任根边界）**——Windows Authenticode 签名 / macOS 公证 / 安装包完整性校验（CI 打包阶段对主程序与 FFI 库做完整性清单），封堵「替换主程序 / FFI 库内嵌主动联网上传」类信任根攻破。

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

---

