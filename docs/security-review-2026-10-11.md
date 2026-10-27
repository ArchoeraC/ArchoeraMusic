# 安全评审问题台账（2026-10-11）

> 状态：**修复中**——第一批（文档澄清，SEC-04/07/14/15/17/18/19/20/28/29）已完成（ed17b5f1）；
> 第二批（凭据统一，SEC-01/02/03）已完成（SEC-02/03：bb7d5787；SEC-01：0ee148f2，补强 eaf4d061）；
> 第三批（防护加固）SEC-05/08/34 文档澄清（bb7d5787）、SEC-09 日志脱敏（be7847b4）、SEC-06 KDF 参数上限（840e6775）已完成；
> 第四批（功能面加固，SEC-10/11/12/13/16/30/31/32/33）已完成（SEC-11/33：84ffd9ec；SEC-12：831a541b；
> SEC-31：57ff8c8c；SEC-10/13/16/30/32 文档：a39ffd41）。
> 第五批（发布供应链，SEC-21/22/23/24/25/26/27）已完成（8e0aee31）——CI/签名溯源加固见
> [supply-chain.md](supply-chain.md)；SEC-22 经 GitHub ruleset 开启 Code Owners 评审。
> **第六批（残留代码加固，2026-10-12）**：SEC-09 单字母查询键 `p/t/s` 上下文掩码（原生 `archoera_log_scrub` + Dart `Log.scrub`）、
> SEC-05 退避状态内嵌 `master-share` 份额槽位（[ShareBundle](../app/core/vault/src/ShareBundle.cs)）、
> SEC-08 构建期 FFI 库 SHA-256 完整性清单 + 运行期校验（[native_integrity.dart](../app/lib/services/native_integrity.dart)）、
> SEC-10 MCP 访问密钥改由凭据保险库承载（`prefs.json` 不再落明文）。逐项状态见 §1。
> **第七批（架构收敛，2026-10-12）**：SEC-19 删除测试明文后端 `InsecureFileStore` / `ARCHOERA_VAULT_INSECURE_FILE_STORE`
> （测试改用生产 `FileStore`）；SEC-03 `StreamingStore.preloadSecrets()` 不再批量解密，改 `loadSecret(id)` 按需单条、
> 不写回长驻 UI 状态。**附带修复**：`VaultFile.ReadHeaderOs` 未跳过 `K_vault(32B)` 导致 file 后端 OS 模式 vault 被
> 误判（`IsFileModeVault` 失败 → `SHARE_BACKEND_MISMATCH`）——已修正。
> **第八批（红队复验 + Rust 移植回归修补，2026-10-12）**：对 vault-rs 做「非常规撬库」红队复验（本地 Linux 原生 +
> msvc-wine/Wine + macOS SDK 交叉编译），发现并修复 **Rust 移植回归**与**文件系统面**共 4 项
> —— SEC-35（Rust 版无 `mlock`/`VirtualLock`/`MADV_DONTDUMP`，文档却称「已有」）、
> SEC-36（Rust 版 zeroize 覆盖不全：`get`/`set` 明文、会话主密钥、读者缓冲）、
> SEC-37（`.tmp`/`.bak` 符号链接写入穿透 → 覆盖任意文件 / vault 被替换为符号链接）、
> SEC-38（`.tmp` 为 FIFO 时保存路径无超时**永久阻塞**）；另具体化 SEC-39（同用户边界，属声明内残余）。
> 并补 **SEC-41**（沙箱只武装 `serve`，一次性命令未硬化）。
> **复核撤回项**：初判「应用层 `vault.auth` 锚点只写不读」，复核代码后**撤回** ——
> [vault_process.dart](../app/lib/services/security/vault_process.dart) 的 `_verifyAnchor` 在每次会话前
> 与握手锚点做 TOFU 比对（不一致 → `vault 锚点不一致：凭据库可能已被替换，拒绝服务`，并有 e2e 用例）。
> 回归覆盖进 `app/core/vault-rs/test.sh`（memguard + 符号链接/FIFO + 沙箱完整性/非自毁 + 黄金夹具）与
> `test-windows.sh`（VirtualLock + 夹具跨 OS 读取）。本轮另补 **SEC-42**（沙箱被破坏的语义闭环）。
>
> **App 层收口（同日）**：SEC-47（应用层 21 读 / 18 写 / 擦除器的「裸」文件调用统一走 `SafeFile`）。
> **收尾复查补四项（同日）**：SEC-43（写入侧容量上限缺失 → 自锁）、SEC-44（退避状态读取未防护 →
> 植入 FIFO 即挂死/OOM，同类读侧问题）、SEC-45（本轮自身引入的并发 tmp 互删竞争）、
> **SEC-46（并发写语义定稿：兼容并发——阻塞式跨进程写锁，消除静默丢更新）**。四项均已修复并加回归。
>
> **C# 版退役（2026-10-12）**：`app/core/vault/`（C# NativeAOT）**已删除**（不再进入任何平台产物），
> 字节/协议兼容改由 `app/core/vault-rs/testdata/` 的**冻结黄金夹具**锚定，活体 oracle
> `app/core/vault-rs/cross_parity.sh` 一并删除；CI/构建（flake、dependabot、security-audit、
> CMake/bat/sh 注释、CONTRIBUTING、docs）已同步。**下文历史条目中指向 `app/core/vault/**` 的
> 「关键位置」按当时记录保留**（该实现已不在仓库中）。
> **本轮重构（2026-10·Vault 重架构）**：模式收敛为 **crypto（默认，`'C'`）/ slots（`'S'`：m1 / m2a / m2b）**，
> 旧 v1（OS 2-of-2）/ v2（口令）/ v3（设备密封·多封装）**移除**（`DeviceEntropy.cs`/`Fingerprint.cs` 删除、
> `init`/`init-password`/`init-device`/`switch-mode`/`upgrade-device`/`rebind`/`clear-device-seal`/
> `set-recovery-password`/`clear-recovery-password` 命令移除）；旧 vault 文件报「vault 版本不兼容」，**无迁移**。
> 本轮同时落地：**F3** 父进程身份校验（**移除** `ARCHOERA_VAULT_PARENT_OK`，改由 OS 提供 pid + 可执行文件路径比对）；
> **F4** 进程自我保护（Linux seccomp-BPF denylist + DUMPABLE/CORE/PDEATHSIG、Windows ACG/CIG 等缓解、macOS 仅 RLIMIT_CORE，全 best-effort）；
> **F5** **key1 签名的原生完整性清单**（取代 OS 代码签名承诺，SEC-08 升级）；slots 容器尾部 HMAC（verify-before-decrypt）、
> KDF 上下限、`Destroy` 覆盖 `.bak` + `device.key`。逐项状态见 §1；SEC-25「OS 签名」改为**不推进**（应用层清单为信任根）。
> **仍未关闭（已知接受 / 外部依赖）**：SEC-25 信任根硬上限（替换主程序 / 同用户运行期注入，无 OS 签名/硬件根时不可防，
> 属已声明残余）；SEC-03 残余（Dart `String` 不可 zeroize，单条明文在一次会话内仍短暂驻留）；
> SEC-05 slots 模式（m1/m2a/m2b）份额现场派生、退避仍回退明文 `vault.lockout`（crypto 模式已内嵌 `master-share`）。
> **第九批（红队复验：宿主进程硬化，2026-10-14）**：授权对**应用宿主进程**做同用户取明文复验 →
> **SEC-48**（高）：宿主未硬化，`kill -SEGV` 产 core 即取出明文登录凭据（绕过 m2a 三因子，实测复现）。
> 修复：新增平台 ABI `apl_harden_process()`（Linux/macOS `RLIMIT_CORE=0`；Windows 关 WER 转储/错误框 best-effort），
> Dart 在桥接 `apl_init` 后立即调用；release 生效。复验：不再产 core。**`PR_SET_DUMPABLE=0` / `PT_DENY_ATTACH` 已撤回**
> —— 实测会打断 vault 父进程血缘校验（读父 exe 被内核拒绝）致凭据库不可用；同用户读内存属 SEC-25 残余。
> 证据与残余见 §8.6。**同批**：Linux `crypto`（LEGACY）后端由 V1 桩补为**纯 Rust D-Bus/Secret Service 真实现**
> （兼容 KDE `CreateItem` 签名差异；无新依赖、沙箱未改；`crypto` 在 Linux 恢复可用）——补齐 [credential-vault-plan.md](credential-vault-plan.md) §8 的「libsecret 真机待验证」。
> 修复后逐项把「状态」改为「已修复」并注明提交 / 版本
> 范围：**文档层评审**——只读仓库文档与安全相关配置（CI 工作流 / 打包 / 工具脚本 / hooks），未做代码审计、未运行程序；
> 重点为 **vault 文档未覆盖**的风险面，第二轮（2026-10-11）扩面到 **CI / 发布供应链** 与 **平台能力 / 子系统 / 文档一致性**。
> 关联规范：[vault-security-notes.md](vault-security-notes.md)（vault 安全声明规范文本）· [credential-vault-plan.md](credential-vault-plan.md) ·
> [device-bound-vault-plan.md](device-bound-vault-plan.md) · [vault-scheme-comparison.md](vault-scheme-comparison.md) · [SECURITY.md](../SECURITY.md)
> 使用方式：修复以本表 ID 为准；新增发现追加编号，不删旧项（保留审计轨迹）。

---

## 0. 评审方法与边界

- **方法**：交叉比对 vault 四份文档与 `architecture` / `privacy` / `SECURITY` / `CONTRIBUTING` /
  `mcp` / `unified-logging` / `download-module` / `local-library` / `neko-source-identity` /
  `audio-kernel-zig` / `ffi-libs-layout-plan` / `downloader-identity-plan` 及 `docs/archive/`。
- **第二轮扩面（2026-10-11，其它位置）**：CI 与发布供应链（`.github/workflows/build-all.yml`、
  `.github/actions/build-linux/action.yml`、`.github/CODEOWNERS`）、打包（`packaging/windows/archoera_music.iss`、
  `packaging/linux/*`）、工具脚本（`app/tool/sign_release.sh` / `verify_release.sh` / `sign_watermark.sh`）、
  hooks（`.githooks/pre-commit`）、平台能力（`platform-native-bridge.md` / `platform-capability-facade.md` /
  `CROSS_PLATFORM_CAPABILITY_IMPROVEMENT.md` / `module-on-demand-load-plan.md`）与内存稿
  （`MEMORY_AND_TRIMMING_DEEP_DIVE.md`）。
- **边界**：本文档所述为**文档描述 / 配置可推出的风险**，是否真实可利用须经代码审计与真机验证确认；
  文档引用行号可能随后续编辑漂移，以**章节标题**为准。
- **判定口径**：`❌ 未提` = vault 文档未把该风险列入声明 / 风险表；`⚠️ 高估` = 文档提到但定性高于实际效力。

---

## 1. 问题台账（汇总）

| ID | 严重度 | 主题 | 关键位置 | vault 文档覆盖 | 状态 |
|---|---|---|---|---|---|
| SEC-01 | 高 | 第二套密钥体系 `secret.key` + `user.db` `enc:v1:` 未纳入 vault | architecture §8；credential-vault-plan §3.1/§4 | ❌ 未提 | 已修复（第二批，0ee148f2） |
| SEC-02 | 高 | v4-file 单因子 + `ARCHOERA_VAULT_SECRET_KEY` 主密钥走 env | vault-scheme-comparison §1/§4；vault-security-notes | ❌ 未提 | 已修复（第二批，bb7d5787） |
| SEC-03 | 高 | 启动预取全量明文常驻 Dart 内存，与「用后即弃」矛盾 | credential-vault-plan §8.2 | ❌ 未提 | 已修复（声明 bb7d5787；**代码收敛·第七批 2026-10-12**：preload 不再批量解密，`loadSecret` 按需单条；**本轮重构 2026-10 复核**：模式重构未回退该收敛） |
| SEC-04 | 高 | PROD marker 被当作「二进制替换主防线」，实为可伪造字符串 | credential-vault-plan §3.8/§8.4；vault-security-notes §二进制替换防护 | ⚠️ 高估 | 已修复（文档·第一批，ed17b5f1） |
| SEC-05 | 中 | `vault.lockout`/`vault.auth`/`vault.marker` 同用户可写 → 退避 / 锚点 / 崩溃标记可绕过 | credential-vault-plan §8.4；vault-security-notes §份额覆盖 | ❌ 未提 | 已修复（文档·第三批 bb7d5787；**代码加固·第六批 2026-10-12**：crypto 模式退避内嵌 `master-share`；**本轮重构 2026-10**：slots 模式份额现场派生、退避仍回退明文 `vault.lockout`——已声明残余） |
| SEC-06 | 中 | Argon2id KDF 参数无加载上限 → 解锁前内存 / CPU DoS | credential-vault-plan §5/§8.6 | ❌ 未提 | 已修复（第三批，840e6775） |
| SEC-07 | 中 | `ARCHOERA_VAULT_PARENT_OK` 由发起方注入 → 血缘 + 握手可自造绕过 | credential-vault-plan §3.8/§8.4 | ⚠️ 高估 | 已修复（文档·第一批，ed17b5f1） |
| SEC-08 | 中 | FFI 库 / 二进制加载顺序劫持（按文件名 + 系统搜索路径） | ffi-libs-layout-plan（Dart 路径解析）；vault-security-notes §二进制替换防护 | ❌ 未提 | 已修复（文档·第三批 bb7d5787；**代码加固·第六批 2026-10-12**：构建期 SHA-256 清单 + 运行期校验；**本轮重构 2026-10**：升级为 **key1 签名的清单**（`ARCHOERA-NATIVE-MANIFEST.sig1`，内嵌公钥验签 fail-closed），vault 二进制 spawn 前校验；残余=主程序自身无法自证） |
| SEC-09 | 中 | 全链路日志无脱敏，vault stderr 转发入明文日志 | unified-logging §2/§3；archive/robustness-improvement-plan §2 | ❌ 未提 | 已修复（第三批 be7847b4；**第六批 2026-10-12** 补 p/t/s 单字母查询键掩码） |
| SEC-10 | 中 | MCP 密钥明文落盘；局域网模式为明文 HTTP | mcp §1/§5 | ❌ 未提 | 已修复（文档·第四批 a39ffd41；**代码加固·第六批 2026-10-12**：密钥改存 vault，prefs.json 不落明文） |
| SEC-11 | 中 | 下载 / 整理的文件路径由元数据派生，`subDir` 未清洗 `..` | download-module §3.3；local-library §刮削 | ❌ 未提 | 已修复（第四批，84ffd9ec） |
| SEC-12 | 中 | 原生 HTTP 客户端重定向未限制降级 / 内网 / 非官方主机 | audio-kernel-zig（2026-10-01 / 2026-10-07 落地） | ❌ 未提 | 已修复（第四批，831a541b） |
| SEC-13 | 中 | 设备指纹与项目自身红线（CONTRIBUTING §2.5）冲突 + 隐私政策未披露 | CONTRIBUTING §2.5；device-bound-vault-plan §5.1；downloader-identity-plan §3.1；privacy §二 | ❌ 未提 | 已修复（文档·第四批，a39ffd41） |
| SEC-14 | 低 | vault 安全声明 env 清单不完整 | vault-security-notes §测试明文存储/§二进制替换防护 | — | 已修复（文档·第一批，ed17b5f1） |
| SEC-15 | 低 | OS 份额共享只写「应用副本覆盖」，未写「第三方应用可读」 | vault-security-notes §份额覆盖风险 | ❌ 未提 | 已修复（文档·第一批，ed17b5f1；**2026-10-14** Linux libsecret 补实现后在 vault-scheme-comparison §4 补写「同会话应用无客户端侧 ACL」残余） |
| SEC-16 | 低 | 迁移 / 模式切换跨存储的崩溃一致性未列风险 | device-bound-vault-plan §8；credential-vault-plan §3.4 | ❌ 未提 | 已修复（文档·第四批，a39ffd41；**代码补强 2026-10-14**：方案切换在 `init` 后**自验证**（`VaultProcess.verifyUnlock` 用刚输入口令真实解锁一次），失败即回滚快照（旧库原封不动）；且**先持久化方案再丢弃旧容器**——消除「新库口令对不上 + 旧库已销毁」与「容器新 / pref 旧」两类不可解态，见 §8.7） |
| SEC-17 | 低 | architecture 内部残留（`sessions` 表已废弃 vs cookie 落点） | architecture §7.4/§8 | — | 已修复（文档·第一批，ed17b5f1） |
| SEC-18 | 低 | 归档评分件与现行口径不一致（明文密码 / 无哈希 / GetUsers） | archive/archoera-robustness-score §6 | — | 已修复（文档·第一批，ed17b5f1） |
| SEC-19 | 低 | 测试后门 `ARCHOERA_VAULT_INSECURE_FILE_STORE` 无删除里程碑 | vault-security-notes §测试明文存储 | ⏳ 已声明计划 | 已修复（文档·第一批 ed17b5f1；**后门已删除·第七批 2026-10-12**：移除 `InsecureFileStore`，测试改用生产 `FileStore`） |
| SEC-20 | 合规 | 声明禁止绕过访问控制，实现却利用服务端 UA 旁路 | software-declaration §五；neko-source-identity；audio-kernel-zig 2026-10-07 | ❌ 未提 | 已修复（文档·第一批，ed17b5f1）；**已消除（2026-10-27：NekoMusic 音源支持整体移除）** |
| SEC-21 | 中 | GitHub Actions 依赖按可变主版本标签固定、未 pin SHA（含签名作业） | build-all.yml；actions/build-linux | — | 已修复（第五批，8e0aee31，见 supply-chain.md） |
| SEC-22 | 中 | 关键路径无强制评审（`protect-main` Required approvals=0，CODEOWNERS 不生效） | .github/CODEOWNERS；AGENTS.md §仓库保护 | — | 已修复（第五批，8e0aee31：ruleset 开启 Require review from Code Owners） |
| SEC-23 | 高 | 发版 tag 可指向未评审提交 → CI 构建并签名攻击者代码 | build-all.yml（`on.push.tags`+release 构建 `github.ref`） | — | 已修复（第五批，8e0aee31：release 作业校验 tag 祖先） |
| SEC-24 | 中 | 标签名直接内插进 shell（`${{ github.ref_name }}` 命令注入反模式） | build-all.yml:990 | — | 已修复（第五批，8e0aee31：改用 `$GITHUB_REF_NAME`） |
| SEC-25 | 中 | 无构建溯源 / SBOM；macOS 仅 ad-hoc、Windows 未签名（信任根承诺未兑现） | sign_release.sh；build-all.yml（ad-hoc 注释） | — | 已修复（第五批，8e0aee31：provenance+SBOM；**本轮重构 2026-10**：**OS 代码签名不推进**——应用层 **key1 签名清单（F5/SEC-08）为信任根**，分发渠道靠包管理器/外层 `.sig1`；替换主程序/同用户注入属**已声明硬上限残余**，见 supply-chain §2） |
| SEC-26 | 中 | 无依赖漏洞扫描（无 dependabot / 各生态 audit） | .github；robustness-improvement-plan §3-12 | — | 已修复（第五批，8e0aee31：dependabot.yml + security-audit.yml） |
| SEC-27 | 中 | CI 测试面过窄（仅 widget/vault 冒烟，非全量） | actions/build-linux §Test | — | 已修复（第五批，8e0aee31：完整 flutter test + 各模块单测） |
| SEC-28 | 中 | 过时设计稿主张运行期提权 + JVM 核心（违反红线） | CROSS_PLATFORM_CAPABILITY_IMPROVEMENT.md | — | 已修复（文档·第一批，ed17b5f1） |
| SEC-29 | 低 | 平台能力文档与现行架构/红线冲突（纯 Dart/插件通道 vs 原生桥接） | platform-capability-facade.md §4 vs §7.3 | — | 已修复（文档·第一批，ed17b5f1） |
| SEC-30 | 低 | `SystemLocation` 敏感权限缺授权/可关闭语义 | platform-capability-facade.md §2.1/§3 | — | 已修复（文档·第四批，a39ffd41） |
| SEC-31 | 中 | deep link 与 `apl_reveal_path` 外部输入校验未声明 | platform-native-bridge.md §3.1 | — | 已修复（第四批，57ff8c8c） |
| SEC-32 | 中 | Subsonic 认证/传输模式未定义（token vs 明文密码、http vs https） | architecture §7；privacy §5.2 | — | 已修复（文档·第四批，a39ffd41） |
| SEC-33 | 低 | 下载临时文件与已存在同名路径（符号链接）处理未定义 | download-module.md §3.3 | — | 已修复（第四批，84ffd9ec） |
| SEC-34 | 低 | 多运行时同进程的信号处理器/全局符号冲突（DoS/稳定性） | module-on-demand-load-plan.md §2；audio-kernel-zig 2026-10-02 | — | 已修复（文档·第三批，bb7d5787） |
| SEC-35 | 中 | **Rust 版 vault 无 `mlock`/`VirtualLock`/`MADV_DONTDUMP`**（文档多处称「mlock 缓冲（已有）」，实际仅 C# `MemGuard` 有）→ 主密钥与明文可被换出到 swap / pagefile / hiberfil | vault-rs `serve.rs`/`service.rs`；credential-vault-plan §3.6；vault-security-notes §内存 | ⚠️ 高估 | 已修复（第八批：新增 `src/memguard.rs`——每缓冲**独占页**锁定（页对齐，防相邻缓冲 `munlock` 误解除）、`MADV_DONTDUMP`、启动提额；`selftest-mem` + 会话期 `VmLck>0` 回归） |
| SEC-36 | 中 | **Rust 版 zeroize 覆盖不全**：`get` 明文与 base64 响应、`set` 解码明文、会话主密钥、读线程行缓冲均直接 drop（C# 对应位置为 `ZeroMemory`/`LockedBuffer`）→ Windows 上实测可扫描到已删除凭据残留 | vault-rs `serve.rs`；C# `ServeSession.cs` | ⚠️ 高估 | 已修复（第八批：明文/口令/主密钥/KEK 收口到 `LockedBuffer`/`Zeroizing`；std 全局 stdout/stdin 缓冲改**原始句柄 + 自有可零化缓冲**） |
| SEC-37 | 中 | **敏感文件符号链接写入穿透**：`.tmp`/`.bak`（含 `secret.key.tmp`/`device.key.tmp`）被预置符号链接时，`File::create`/`fs::copy` 会写入链接指向的任意文件；`.tmp` 场景还会把 vault 文件本身替换为符号链接（重定向后续读写） | vault-rs `format.rs`/`share.rs`/`device.rs`；C# `VaultFile.cs` 同源 | ❌ 未提 | 已修复（第八批：新增 `src/safefile.rs`——读走 `O_NOFOLLOW`+普通文件判定，写走 `O_CREAT\|O_EXCL` 独占 tmp、非普通文件即拒绝、`.bak` 改原子写） |
| SEC-38 | 中 | **`.tmp` 为 FIFO 时保存路径无超时永久阻塞**（`open(O_WRONLY)` 挂死）→ 会话与主密钥驻留无上界、可用性可被单文件击穿（空闲读超时不覆盖写路径） | vault-rs `format.rs`；C# 同源 | ❌ 未提 | 已修复（第八批：`safefile` 拒绝非普通文件 tmp；回归用例含 `timeout` 断言） |
| SEC-39 | 低 | **Windows 无「禁同用户读内存」等价物**：`OpenProcess`+`ReadProcessMemory` 未被 ACG/CIG 等缓解拦截；结合 DPAPI 无 `pOptionalEntropy`（份额可被同用户任意进程解封）→ 同用户进程可直读会话内存 / 离线解出条目明文 | vault-rs `guard.rs` 缓解集；`share.rs` DpapiStore | — | 已声明（第八批：文档具体化；应用层无法封闭——`mlock` 只防换页不防读，故 SEC-35/36 是唯一可减少暴露面的手段） |
| ~~SEC-40~~ | — | ~~应用层 `vault.auth` 锚点只写不读~~ → **复核撤回**：`_verifyAnchor` 已做 TOFU 比对（`get`/`set` 前逐次校验，不一致即 `VaultException`），且 `app/test/vault_process_v4_test.dart` 有 e2e 用例覆盖 | — | — | 撤回（原判定系 grep 大小写失误；`vault.auth` 可被同用户一并改写属 SEC-05 已声明残余） |
| SEC-47 | 中 | **App 层「裸」文件调用**（21 读 / 18 写 / 擦除器 1）：配置目录对同用户可写，植入 **FIFO** 会让 `readAsStringSync`/`openSync` 阻塞在打开阶段（界面/启动冻结）；植入**符号链接**会让读被重定向、**写穿透覆盖链接目标**，而 `data_destroyer` 的覆盖写更会**抹掉任意文件**；超大文件可 OOM | `app/lib/**`（`prefs.json`/`scan_dirs.json`/`streaming_servers.json`/`netease_session.json`/`last_session.json`/`daily_shelf.json`/`download_history.json`/封面/清单与签名等） | ❌ 未提 | 已修复（本轮：新增 `lib/utils/safe_file.dart` —— 读「必须是普通文件」+ 长度上限（`allowSymlink` 可选，兼容 dotfiles）；写「同目录唯一临时名 + rename」（符号链接只被替换不被穿透）；擦除器只擦普通文件；vault 锚点/标记/清单/签名/被校验库统一收口）；回归 `test/safe_file_test.dart`（普通/缺失/目录/符号链接/FIFO/不穿透写/失败不留残） |
| SEC-48 | 高 | **应用进程未硬化 → 同用户「杀进程产 core」即可绕过 vault 取明文凭据**：应用进程必然在内存持有已解密的流媒体凭据（登录 cookie）。同用户攻击者无需口令/设备因子/恢复码，只需 `kill -SEGV <app pid>`（**不需要 ptrace**，同用户可对自身进程发信号）→ 内核产 core → `systemd-coredump` 落盘并对属主**附加可读 ACL** → `coredumpctl dump` 或直接读 `/var/lib/systemd/coredump/*` → `MUSIC_U`/`__csrf`/`_ntes_nuid` 等**明文**直接可用（实测复现）。m2a 三因子被完全绕过；且 core 落盘使泄露**超出进程生命周期**（退化为 L1 磁盘取证）。vault 子进程另有硬化（dumpable=0 + RLIMIT_CORE=0），但**持有明文的宿主进程没有** | `app/native/platform`（新增 `apl_harden_process`）+ `app/lib/services/platform/platform_bindings.dart` | ❌ 未提 | 已修复（2026-10-14，最终形态=**仅禁 core**）：`apl_harden_process()` —— Linux/macOS `setrlimit(RLIMIT_CORE,0)`（子进程继承）、Windows 关 WER 错误框/转储（best-effort）；Dart 在 `PlatformBindings.tryLoad` 中 `apl_init` 后**立即**调用（早于任何凭据入内存）；**release 生效**（debug 保留调试/产核能力）。复验：`kill -SEGV` **不再产 core**（coredumpctl 条数不变）。**已撤回 `PR_SET_DUMPABLE=0`/`PT_DENY_ATTACH`**：二者会让子进程读不到父进程可执行文件路径，**打断 vault 父进程血缘校验 → 凭据库整体不可用**（实测回归：`独立运行被拒：无法读取父进程可执行文件路径`）；该内存读取路径属已声明 L2 残余（SEC-25），Linux 由 `kernel.yama.ptrace_scope=1` 阻断、macOS 由 `task_for_pid` 默认需 root/entitlement 阻断 |
| SEC-46 | 中 | **多会话并发写 = 「最后写者获胜」（静默丢更新）**：`set`/`delete`/`set-kdf`/`init`/`destroy` 均为「加载 → 改 → 保存」，两个会话基于同一份旧状态各自保存时，后写者会**静默覆盖**前者的条目或把重键头部写回（可用性/完整性双危）；此前无任何跨进程互斥 | vault-rs `service.rs`/`safefile.rs` | ❌ 未提 | 已修复（本轮定语义为**兼容并发**：新增 `safefile::DataDirLock`——`flock(LOCK_EX)` / `LockFileEx` **阻塞式**独占（内核事件唤醒，**非轮询**；`EINTR` 重试非忙等）、**崩溃由内核自动释放**、锁范围=单条命令、锁文件 `vault.lock` 走安全打开且**永不删除**（删了会让互斥失效）；`set`/`delete`/锚点/`set-kdf`/`init`/`destroy` 全部取锁）；回归 `test.sh` §16（外部持锁时写命令阻塞、释放后完成；CLI 重键 ∥ serve 写入 → 头部与条目**都在**） |
| SEC-43 | 中 | **写入侧容量上限缺失 → 可用性自毁（自锁）**：`MAX_ENTRY_BYTES(4 MiB)` / `MAX_FILE_SIZE(16 MiB)` 仅在**加载**侧校验 → 一次 4 MiB 明文 `set` 会「回 ok」但库此后无法加载（实测；累计 >16 MiB 同理），只能靠 `.bak` 手工救 | vault-rs `format.rs`（`encrypt_entry`/`save`） | ❌ 未提 | 已修复（第八批补：`encrypt_entry` 校验单条（明文 ≤ 4 MiB−16B）、`save` 校验整库 ≤ 16 MiB，均**落盘前**拒绝）；回归 `test.sh` §15（边界 4194288 B 通过 / +1B 拒绝 + 整库上限 + 未自锁） |
| SEC-44 | 中 | **退避状态文件读取未防护 → 植入即挂死/OOM**：`vault.lockout` 用 `fs::read_to_string` → 植入 **FIFO** 会让 `open` 阻塞在握手路径（无超时覆盖，实测挂死）；符号链接可重定向读取，超大文件可 OOM。vault 文件/`device.key`/`secret.key` 亦存在「读进内存后才判长度」的同类隐患 | vault-rs `lockout.rs`/`format.rs`/`device.rs`/`share.rs` | ❌ 未提 | 已修复（第八批补：新增 `safefile::read_regular_limited`——**读前**按元数据判长度 + 拒绝非普通文件；全部敏感读取改走它，退避状态异常一律视为「无锁定」）；回归 `test.sh` §13.5（FIFO / 符号链接→/dev/zero / 超大文件均正常解锁、不挂死） |
| SEC-45 | 中 | **并发保存的 tmp 互删竞争**（第八批自身引入）：`write_atomic` 的「清理陈旧 tmp」在 4 路真并发保存下会删掉别人正在用的 `<file>.tmp` → 实测 40 次写 2 次失败（`ENOENT`/`EEXIST`） | vault-rs `safefile.rs` | ❌ 未提 | 已修复（第八批补：临时名改为**进程唯一** `<file>.tmp.<pid>` + 兼容清理旧的可预测名；真并发 10 轮 40 次**全部成功、无残留**） |
| SEC-42 | 低 | **「沙箱被攻破」语义未闭环**：主程序侧只有「vault **异常退出** → crash 标记 → `exit(86)`」；而**可观测的蓄意破坏**（加载器注入变量）此前只 `err`+退出码 1 → 被应用判为「主动报错，不联动」，不触发 fail-closed；文档亦未区分「可观测破坏 / 不可观测攻破 / 数据完整性失败」三类 | vault-rs `guard.rs`/`main.rs`；[vault_process.dart](../app/lib/services/security/vault_process.dart) | ⚠️ 未明确 | 已修复（第八批：新增 `SANDBOX_BREACH_EXIT = 87`——注入面被破坏时打印 `err` 后以 87 终止；应用侧 `markerForExit` 把 87 与信号终止同等判为 crash → `exit(86)` **连带主程序退出**；**明示不做**猜测式检测、**明示不删数据**；回归：`test.sh` 注入用例断言 87、`vault_process_v4_test` 断言 87→crash） |
| SEC-41 | 中 | **沙箱只武装 `serve`**：`verify_and_arm()` 仅在 serve（与 seccomp 自检）调用 → `init-*`/`set-kdf`/`destroy`/`status` 等一次性命令**未硬化**（`PR_SET_DUMPABLE=1`、`RLIMIT_CORE` 默认（可产含口令的 core）、无 seccomp / Windows 无缓解）；`init-m2a` 还会在内存中持有恢复码，KDF 期间窗口可达秒级 | vault-rs `main.rs`/`guard.rs`；C# 同源 | ❌ 未提 | 已修复（第八批：拆出 `guard::harden_process()`，`main` **所有命令**入口先硬化；血缘校验仍仅 `serve`（保证打包布局下用户仍可手工 `destroy <dir>`）；新增 `selftest-seccomp list` 逐条验证 denylist；回归 13.1/13.2） |

---

## 2. 高危

### SEC-01 · 第二套密钥体系：`secret.key` + `user.db` 字段级加密，未纳入 vault

- **现象**：Subsonic 用户 / 收藏 / 播放列表存 `database/user.db`，敏感字段以 `enc:v1:` AES-256-GCM
  字段级加密，**密钥自举到 `dataDir/secret.key`**；旧数据迁移「密文原样搬运不重加密」。
- **证据**：`architecture.md` §8（数据存储表与拆分原则）；`CONTRIBUTING.md` §10（`凭据落盘一律走 vault（2-of-2）或 enc:v1: 字段级加密`）。
  vault 三份主文档（credential-vault-plan / vault-security-notes / device-bound-vault-plan）**完全未提** `user.db` / `secret.key`；
  而 `credential-vault-plan` §3.1、§4 声称「统一承载：流媒体服务器密码、本地 Subsonic 账号」——**同一份凭据两套体系、口径冲突**。
- **影响**：用户即便把 vault 升到 v2 / v3（Argon2id / 设备绑定），**Subsonic 服务器账号密码仍只由同机明文密钥文件单点保护**；
  备份 / 取证 / 磁盘克隆拿到 `dataDir` 即可解出，vault 的强度提升不覆盖此类凭据。
- **附带**：`secret.key` 与 `vault-scheme-comparison` §v4-file 的密钥**同文件名**，是否同一文件、作用域是否交叉未说明（需代码确认）。
- **修复方向**：二选一并统一文档——① 把 `user.db` 敏感字段纳入 vault 统一承载（消灭第二套密钥 / 或在 v1-v3 之上为 `secret.key` 定义保护等级）；
  ② 明确声明 `enc:v1` 为**独立降级体系**（单因子、同机密钥），在 vault 文档与隐私政策中如实标注其边界。

### SEC-02 · v4-file 单因子模式与主密钥 env 未进入安全声明

- **现象**：`vault-scheme-comparison` §1/§4 记载 **v4-file**：`init-file` 或 `ARCHOERA_VAULT_BACKEND=file` 创建，
  主密钥 K 整体落盘 `secret.key`（0600），**可被 `ARCHOERA_VAULT_SECRET_KEY` env 覆盖**。
- **证据**：`vault-security-notes.md`（规范文本）只声明 `ARCHOERA_VAULT_INSECURE_FILE_STORE` 与 `ARCHOERA_VAULT_BIN`；
  与 `credential-vault-plan` §3.8「argv/环境不携带任何凭据与握手材料」及 `CONTRIBUTING.md` §10「显式 env 只服务测试/CI，生产路径不得设置」**直接矛盾**。
- **影响**：主密钥经环境变量传递会出现在 `/proc/<pid>/environ`（同用户可读），并可能进入日志、崩溃转储、CI 记录、systemd 单元；
  单因子文件密钥泄露即凭据全泄露（弱于 v1 OS 存储），但安全声明文档从未告知存在此模式。
- **修复方向**：在 `vault-security-notes.md` 增列 v4-file 与相关 env 的**信任边界声明**；若要保留 `SECRET_KEY` env，
  明确其仅在测试 / 容器场景且需注明风险；否则改为仅经 stdin 传入。

### SEC-03 · 启动预取使明文常驻内存，违背「按需流式解密」

- **现象**：`VaultSessionStore.initialize()` 后 `await StreamingStore.preloadSecrets()`，**启动即解密全部流媒体凭据**
  并以写穿缓存作为同步 `load()` 的数据源。
- **证据**：`credential-vault-plan` §8.2 与 §4 改动点表（`main.dart` / `StreamingStore.preloadSecrets`）；
  与 §2.3「按需流式解密，用后即弃」、§3.3「Dart 侧仅注入那一行持有明文，不进状态对象」**自相矛盾**。
- **影响**：Dart 字符串**不可 zeroize**（GC 管理、会复制、不受 §3.6 mlock 覆盖），故明文在 Dart 堆常驻整个进程生命周期；
  §3.6 的 mlock / MADV_DONTDUMP / zeroize 只覆盖 C# / Rust 缓冲，**Dart 侧明文未受任何内存保护**。
- **修复方向**：改为按需解密（注入前单次解密即弃），或明确把「预取常驻明文」作为**已知接受项**写入风险表并给出缓解
  （主进程 `PR_SET_DUMPABLE=0` / `RLIMIT_CORE=0` / 禁止 swap 的实际覆盖范围需确认）。
- **第七批落地（2026-10-12）**：`preloadSecrets()` 已**去掉逐服务器解密循环**（仅 vault 惰性初始化 + 模式探测）；
  新增 `StreamingStore.loadSecret(id)` 按需**单条**解密，且不写回长驻 `StreamingState`——带凭据配置仅临时构造给
  客户端（`resolvedServer`），编辑表单按需解密预填。`save()` 改为「未知凭据跳过，绝不写空覆盖」。
  **残余**：Dart `String` 不可 zeroize，单条明文在一次会话内仍会短暂驻留堆中（架构性，无法在 Dart 侧消除）。

### SEC-04 · PROD marker 被高估为「二进制替换主防线」

- **现象**：文档把握手应答尾部 `BuildInfo.Marker`（PROD/TEST 指纹）称为二进制替换防护的**第二道（协议内）防线**，
  并在默认路径下「缺失或非 PROD → 杀进程 + 删副本 + fatal 态」。
- **证据**：`credential-vault-plan` §3.8、§8.4；`vault-security-notes.md` §二进制替换防护；`CONTRIBUTING.md` §10「PROD marker 双重校验逻辑不得削弱」。
- **影响**：marker 只是**字符串指纹，无签名 / 无认证**。攻击者可自行编译含后门的 vault 并输出同名 `ARCHOERA-VAULT-PROD-*`，
  同时通过 `--version` 与握手校验；`ARCHOERA_VAULT_BIN` 显式指定（notes §二进制替换防护）更直接跳过 PROD 校验。
  故该机制只能防「误用测试构建」，**不能防「替换二进制」本身**——与文档「主防线」定性不符。
- **修复方向**：修正文档定性为「防测试构建误用」；二进制完整性改由 **key1 签名的原生完整性清单（F5/SEC-08）** 承接（`ARCHOERA-NATIVE-MANIFEST.sig1`，内嵌公钥验签 + 逐文件摘要，vault spawn 前校验），**不再依赖 OS 代码签名**（Authenticode/公证不推进，见 SEC-25）。

---

## 3. 中危

### SEC-05 · lockout / auth / marker 同用户可写 → 防护可绕过

- **现象**：`vault.lockout`（指数退避）、`vault.auth`（锚点）、`vault.marker`（崩溃标记）均为 `dataDir` 下普通文件，权限未定义。
- **证据**：`credential-vault-plan` §8.4（锚点 `$dataDir/vault.auth`、标记 `$dataDir/vault.marker`）；`vault-security-notes.md` §份额覆盖（恢复提示列出这些残留文件）。
- **影响**：同用户攻击者可 ① 删除 `vault.lockout` 重置退避 → Argon2id 在线爆破变无限次；
  ② 同时替换 `credentials.vault` + `vault.auth` → 锚点校验（§8.6 声称可拒绝路径遍历 / 替换）在同用户下失效；
  ③ 伪造 `vault.marker`：写 `crash` 触发主程序 `exit(86)` + 「仅允许退出」fatal 门（DoS），或写 `clear` 掩盖真实崩溃。
- **修复方向**：文档如实声明这些文件为「同用户可写、不构成对同用户攻击者的防线」；
  锚点 / 退避状态应移入 OS 安全存储或做完整性绑定（HMAC 于 OS 份额）；崩溃标记需防伪造或降级为提示。

### SEC-06 · Argon2id KDF 参数无加载上限（解锁前 DoS）

- **现象**：`VaultLimits` 仅限制文件 ≤16MB / 条目 ≤10 万 / 单条 ≤4MB；v2 / v3 头部的 `m / t / p`（u32）**不在限内**，
  且文档未说明 KDF 参数是否被 AEAD 覆盖 / 认证。
- **证据**：`credential-vault-plan` §5 风险表、§8.6 攻击面演练（已修条目数 / 长度 / 文件大小，未涉 KDF 参数）。
- **影响**：恶意构造头部 `m≈2^32` → 解锁时先执行巨量内存分配（发生在任何认证之前）→ 本机内存 / CPU DoS。
- **修复方向**：为 `m / t / p` 增加加载上限并快速拒绝；确认头部是否需纳入认证。

### SEC-07 · 血缘 + 握手可被环境变量自造绕过

- **现象**：父进程白名单由发起方经 `ARCHOERA_VAULT_PARENT_OK`（逗号分隔可执行名）注入。
- **证据**：`credential-vault-plan` §3.8、§8.4（PlatformGuard）。
- **影响**：攻击者自行 spawn vault 时自带该 env + 自选 `H/C` 即可通过血缘与握手，随后 `get <uid>` 取走全部凭据；
  §3.8 / §8.4 将握手表述为可防「独立工具滥用与自动化」，**同用户下并不成立**（真实边界其实与 §1.2-4/5 一致，措辞过度）。
- **修复方向**：文档收口表述——血缘 / 握手不防同用户攻击者，仅防「无主进程上下文的误用与自动化」；白名单应来自不可被调用方伪造的锚点。
- **本轮重构（2026-10·F3）处置**：**`ARCHOERA_VAULT_PARENT_OK` 已完全移除**——父进程身份校验改由 **OS 提供**的 pid + 可执行文件路径
  （Linux `/proc/<ppid>/exe`、macOS `proc_pidpath`、Windows `QueryFullProcessImageNameW`）与「由 vault 位置推导的预期主程序路径」比对，
  **不读任何 env**。残余（如实）：同用户攻击者可在预期路径放置自造二进制再 spawn，**无法与「主程序被替换」区分**（L4 硬上限）。

### SEC-08 · FFI 库 / 二进制加载顺序劫持

- **现象**：引擎等库按**文件名**加载（`DynamicLibrary.open('libarchoera_mediaengine.so')`，依赖系统搜索路径），
  另有 `NativeLibPaths` 祖先链查找。
- **证据**：`ffi-libs-layout-plan.md`（Dart 路径解析条目）；`vault-security-notes.md` 仅覆盖 vault 本体二进制。
- **影响**：`LD_LIBRARY_PATH` / exe 同目录可写 / Windows DLL 搜索顺序 → 库加载劫持（属 L2，非 L4）；
  主程序与其余 7 个 FFI 库无完整性校验，vault marker 保护亦依赖 Dart 侧解析路径可靠。
- **修复方向**：文档补充「加载顺序劫持」威胁项；加载改绝对路径 / 校验摘要；纳入 §8.5 的完整性清单待办。

### SEC-09 · 全链路日志无脱敏，vault stderr 转发入明文日志

- **现象**：`<dataDir>/logs/archoera.log` 默认开、4 MiB、明文；vault 子进程 stderr 由 Dart 转发进同一 sink；
  引擎 / FFmpeg / native-http 记录完整 URL。
- **证据**：`unified-logging.md` §2（落盘 / 上限 / 无缓冲）、§3（vault 子进程转发）；`audio-kernel-zig.md`（transport 日志口径）。
  归档件 `robustness-improvement-plan.md` §2 曾要求「错误信息禁止携带 token/明文凭据 + token/cookie/密码自动掩码」，
  而现行 `unified-logging.md` **无任何脱敏机制**。
- **影响**：带签名参数 / token 的取流 URL 与错误信息可明文落盘（`vault-security-notes` 的「不落日志」只覆盖 vault 自身）。
- **修复方向**：在日志核心落地敏感字段掩码（token / cookie / password / URL query）；对 vault stderr 转发做二次过滤；
  文档补充「日志可能含 URL 参数、默认明文、可关闭」的声明。

### SEC-10 · MCP 控制服务：密钥落盘明文 + 局域网明文 HTTP

- **现象**：访问密钥恒定时间比较但**明文落 `prefs.json`**；可选「允许免密钥访问」；「允许局域网访问」绑定 `0.0.0.0`。
- **证据**：`mcp.md` §1、§5。
- **影响**：同用户任意本地进程可读 `prefs.json` 取密钥（「要求密钥」对本地进程无隔离）；
  局域网模式下走**明文 HTTP（无 TLS）**，密钥 / 搜索词 / 播放内容可被嗅探；`Origin` 校验只防浏览器 DNS-rebinding。
- **修复方向**：文档明确「密钥防浏览器 / 跨源，不防同用户进程」；局域网模式加说明或改仅回环；
  考虑密钥不落盘 / 仅内存持有。

### SEC-11 · 文件写出路径由元数据派生，`subDir` 未清洗 `..`

- **现象**：下载路径 `subDir` 直接由 `artist` 派生（ByArtist 策略），仅 `filename` 过 `sanitize`；
  `sanitize` 只把 `\/:*?"<>|` 换成 `_`，**不剥离 `..`**。目录整理同样以标签值 + `/` 构建目录树。
- **证据**：`download-module.md` §3.3（路径 & 文件名）；`local-library.md` §刮削（仅目录整理）。
- **影响**：恶意 / 被篡改的平台元数据或本地标签（artist 为 `..` 或含 `/`）→ `destPath` 越出 `rootDir`，任意目录写入。
- **修复方向**：对 `subDir` 与整理模板变量同样做规范化（拒绝 / 替换 `..`、绝对路径、盘符）；文档补充路径清洗契约。

### SEC-12 · 原生 HTTP 客户端重定向面（降级 / 内网 / 非官方主机）

- **现象**：内核自研 HTTP/1.1，跟随重定向 ≤6 跳、「重定向原样保留」；TLS 仅「`std.crypto.tls.Client` + 系统 CA」一句。
- **证据**：`audio-kernel-zig.md`（2026-10-01 原生 HTTP 落地、2026-10-07 头透传）。
- **影响**：媒体 URL 来自平台 / 音源返回，若被劫持可诱导内核向任意主机（含环回 / 内网）发起请求并读响应体（SSRF 面），
  或经 `https→http` 降级泄露带签名的 URL；文档未声明主机名校验 / 证书错误 fail-closed 细节。
- **修复方向**：明确重定向策略（拒绝 scheme 降级、限制内网 / 环回、可选域名白名单）；文档补齐 TLS 校验语义。

### SEC-13 · 设备指纹与项目自身红线冲突 + 隐私政策未披露

- **现象**：v3 设备绑定采集 `machine-id` / `MachineGuid` / `IOPlatformUUID`；下载器持久化用户级设备身份（默认开启）。
- **证据**：`CONTRIBUTING.md` §2.5 红线明文禁止「设备指纹、持久化设备 ID、跨会话跨启动追踪」能力；
  `device-bound-vault-plan.md` §5.1（指纹采集表）；`downloader-identity-plan.md` §3.1（「同一用户 → 指纹稳定（首次生成后不变）」，prefs 持久化）；
  `privacy.md` §二 仅在凭据描述里带「v3 设备绑定」字样，**未披露读取硬件设备标识或持久化设备身份**。
- **影响**：文档层面自相矛盾 + 隐私披露缺口（v3 有 in-app 提示，downloader identity 默认开启且无披露）。
- **修复方向**：统一口径——要么修订 §2.5 红线为「禁止**上传 / 跨应用追踪**，本地设备绑定属列举例外」并补隐私政策披露，
  要么把这些能力降级 / 加显式同意；无论哪种，隐私政策需补「本机设备标识的读取与用途」段落。

---

## 4. 低危 / 文档一致性

- **SEC-14** `vault-security-notes.md` 的 env 清单不完整：仅 `ARCHOERA_VAULT_INSECURE_FILE_STORE` / `ARCHOERA_VAULT_BIN`；
  缺 `ARCHOERA_VAULT_BACKEND` / `ARCHOERA_VAULT_SECRET_KEY` / `ARCHOERA_VAULT_FINGERPRINT` / `ARCHOERA_VAULT_PARENT_OK` /
  `ARCHOERA_VAULT_NO_ABORT`（均影响安全面）。应逐项声明信任边界。
- **SEC-15** `vault-security-notes.md` §份额覆盖风险只写「同一设备上任何一份**应用副本**…覆盖」；
  未写 libsecret 全局 schema / account **无 per-app 隔离** → 同机**第三方应用**同样可读 / 覆盖 S；macOS 若用 GenericPassword 未设 ACL 同理。
  （**2026-10-14 状态**：Linux libsecret 后端已由桩补为真实现（`app/core/vault-rs/src/secret_service.rs`），
  条目按应用 schema + 数据目录作用域；但 Secret Service **无客户端侧 ACL** 属平台边界，已在
  [vault-scheme-comparison.md §4](vault-scheme-comparison.md) 如实声明为残余。）
- **SEC-16** 迁移 / 模式切换的崩溃一致性：`device-bound-vault-plan` §8 与 `credential-vault-plan` §3.4 的
  「先落份额后写 vault，失败回滚」跨**两个存储**，单文件原子替换**覆盖不到两步之间被 kill**；可能留下不可解 vault（丢登录态），风险表未列。
- **SEC-17** `architecture.md` 内部残留：§7.4 仍说 cookie 走「Dart 本地层 + vault」、logout 清 `sessions` 表，
  而 §8 说 `sessions` / `downloads` 表方案已废弃 → 易误读 cookie 实际落点。
- **SEC-18** 归档件 `docs/archive/archoera-robustness-score.md` §6 的「支持明文密码、无哈希 / GetUsers 无权限检查」与
  现行 `architecture.md` §8 的 `enc:v1` 口径不一致（历史件，易被误引用）。建议在归档目录标注其时效。
- **SEC-19** `ARCHOERA_VAULT_INSECURE_FILE_STORE` 测试后门「待删除」（`vault-security-notes.md` §测试明文存储）无删除里程碑；
  建议在本文档登记一个目标版本 / 触发条件（Linux keyring CI 基建就绪）。
  **第七批落地（2026-10-12）**：**已删除**与 `InsecureFileStore`——本机无 headless keyring 时，测试改用**生产 `FileStore`**
  （`ARCHOERA_VAULT_BACKEND=file`），不再需要真实 Secret Service 即可跑通全链路；`VAULT_TESTING` 仅保留构建标记。
  附带修复 `VaultFile.ReadHeaderOs` 未跳过 `K_vault` 的缺陷（file 后端 OS 模式 vault 曾被误判为后端不配对）。

---

## 5. 声明与合规冲突（非内存漏洞）

### SEC-20 · 声明禁止绕过访问控制，实现却利用服务端 UA 旁路

- **现象**：`software-declaration.md` §五 写明「请勿绕过在线平台的技术保护措施、访问控制或服务条款」；
  但实现文档记录：**复用官方客户端 UA 形状**通过 `isNativeClient` 锚定、并利用服务端「空 UA 直接放行」旁路清空 UA。
- **证据**：`neko-source-identity.md`（身份头方案与「不变量」）；`audio-kernel-zig.md`（2026-10-07 头透传与空 UA 修正）。
- **影响**：与本软件自身用户声明相冲突，属披露 / 合规风险（非本地漏洞）。
- **修复方向**：如实调整声明措辞或改用服务端认可的自报标识（`X-Neko-Client` 正向放行）；
  文档明确「版本锚定形状仅通过正则锚定，不冒名品牌」的边界与风险。
- **已消除（2026-10-27）**：NekoMusic 音源支持已整体移除（客户端身份、UA 形状与相关代码均删除），
  本项不再适用；上述证据文档 `neko-source-identity.md` 已随删除下线。

---

## 6. 其它位置：CI / 发布供应链

> 背景：发布产物由 key1（`ARCHOERA_WM_KEY1_PEM`，存于受保护 `release` Environment）签名，因此**构建流水线本身即信任根之一**。

### SEC-21 · GitHub Actions 依赖按可变主版本标签固定、未 pin SHA

- **现象**：所有 `uses:` 只用主版本标签——`actions/checkout@v5`、`actions/upload-artifact@v6`、
  `actions/download-artifact@v7`、`actions/cache@v5`、`actions/setup-go@v6`、`actions/setup-dotnet@v5`、
  `subosito/flutter-action@v2`、`dtolnay/rust-toolchain@stable`、`DeterminateSystems/nix-installer-action@v16`；均未固定到 commit SHA。
- **证据**：`.github/workflows/build-all.yml`、`.github/actions/build-linux/action.yml`。
- **影响**：上游标签可被移动 / 上游账号被入侵 → 在流水线（含处理签名私钥的 release 作业）执行任意代码；`@stable` 尤甚。
- **修复方向**：全部 action pin 到 40 位 commit SHA；用 Dependabot/renovate 定期升级。

### SEC-22 · 关键路径无强制评审（CODEOWNERS 形同虚设）

- **现象**：`.github/CODEOWNERS` 覆盖 `*` 及 `/.github/`、`/app/tool/`、`/packaging/`、`app/lib/app/watermark.dart` → @BetaStudio2；
  但 `AGENTS.md`（§仓库保护）明示 branch ruleset `protect-main` 的 **Required approvals = 0**（单人可自建 PR 自合并）。
- **影响**：拥有写权限者可直接改 CI / 签名工具 / 打包脚本并自合并，等于可改写发布流水线与签名私钥的用途。
- **修复方向**：对上述关键路径启用 `Require review from Code Owners`（或至少 `Require approvals ≥ 1`）。

### SEC-23 · 发版 tag 可指向未评审提交 → CI 构建并签名攻击者代码

- **现象**：`on.push.tags: ['v*']` 触发全平台构建；release 作业构建的是 `github.ref` **即该 tag 指向的提交**；
  `protect-release-tags` 只禁止**更新/删除**已发布 `v*` tag，**不限制新建 tag 的指向**。
- **影响**：有 tag 推送权限者可给任意未合并 / 未评审提交打 `v*`，触发全平台构建，并在维护者批准 `release` Environment 后
  **对攻击者代码签 `.sig1`**（Environment 人工审批是唯一门，但审批者未必注意到 tag 指向非 main 提交）。
- **修复方向**：CI 校验发版 tag 必须指向 main 的祖先提交（`git merge-base --is-ancestor`）或要求签名的 annotated tag；
  收紧谁可创建 `v*` tag。

### SEC-24 · 标签名直接内插进 shell（命令注入反模式）

- **现象**：`.github/workflows/build-all.yml:990` `TAG="${{ github.ref_name }}"`——把 tag 名以模板方式注入 `run:` 脚本。
  `git check-ref-format` 实测**接受** `v1.0$(id)`、`` v1.0`id` ``、`v1.0";id"` 等含 shell 元字符的标签名。
- **影响**：可推送此类标签触发 shell 命令执行（结合 SEC-23 放大）。
- **修复方向**：改用环境变量 `$GITHUB_REF_NAME`（不经脚本模板）；**任何 `run:` 内都不要用 `${{ github.ref_name / github.event.* }}`**。

### SEC-25 · 无构建溯源 / SBOM；macOS 仅 ad-hoc、Windows 未签名（信任根承诺）

- **现象**：release 作业仅用 key1 对已下载 artifact 签 `.sig1`（`app/tool/sign_release.sh`）；
  macOS 构建注释明确 **ad-hoc 签名**（`CODE_SIGN_IDENTITY = "-"`），未见 Windows Authenticode。
- **影响**：`.sig1` 只证明「该 key 签了这份字节」，不证明构建来源 / 可复现；
  而 vault 文档（§1.2-5、§信任根边界）曾把 L4 信任根寄托于「OS 信任链（Authenticode / 公证 / 安装包完整性）」。
- **本轮重构（2026-10）处置**：**OS 代码签名不再推进**（Authenticode / 公证因成本与步骤不可得，不再作为待兑现承诺）。
  应用层信任根改为 **key1 签名的原生完整性清单**（`ARCHOERA-NATIVE-MANIFEST.sig1`，SEC-08）：运行期内嵌公钥验签 + 逐文件摘要、
  vault 二进制 spawn 前校验；分发渠道（deb/rpm/AppImage/flatpak/pkg.tar.zst/nixos）依赖**包管理器签名**，
  Inno `.exe` 依赖**外层 `.sig1`**。用户可用分发公钥**离线核验**。
  **残余（硬上限，如实声明）**：替换主程序 / 同用户运行期注入主程序**无法用应用层清单防住**（验证逻辑在被替换的进程里），
  无 OS 签名 / 硬件根（TPM / Secure Enclave）时无解；清单亦不证明构建可复现。详见 [supply-chain.md §2](supply-chain.md)。

### SEC-26 · 无依赖漏洞扫描

- **现象**：仓库无 `dependabot.yml` / renovate；CI 无 `cargo audit` / `govulncheck` / `dotnet list package --vulnerable` / `npm audit`。
  `docs/archive/robustness-improvement-plan.md` §3 第 12 项「依赖安全扫描」仍未落地。
- **影响**：已知漏洞依赖（FFmpeg / crates / NuGet / pub）不会被发现。
- **修复方向**：启用 Dependabot + 各生态 audit 作业（此项早已登记，长期未闭环）。

### SEC-27 · CI 测试面过窄（回归可能直达发布）

- **现象**：CI 实际只跑 `dart analyze lib`、`flutter test test/widget_test.dart` + `test/vault_session_store_test.dart`、
  `cargo test`（仅 `app/core/shell`）、`zig build test`；**未跑完整 `flutter test`**，未跑 downloader / subsonic 的 `cargo test` / `go test`，未跑 scanner C# 测试。
- **证据**：`.github/actions/build-linux/action.yml`（Test 步骤）；`AGENTS.md` 要求提交前 `flutter test` 全绿。
- **影响**：本地要全量、CI 只冒烟；下载器加解密、平台桥接、vault 其余用例的回归不会被 CI 拦住，可能随发布出去。
- **修复方向**：CI 跑完整 `flutter test`（含 vault / 平台用例，必要时 headless 处理）与各模块单测。

---

## 7. 其它位置：平台能力 / 子系统 / 文档一致性

### SEC-28 · 过时设计稿主张运行期提权 + JVM 核心（违反红线）

- **现象**：`docs/CROSS_PLATFORM_CAPABILITY_IMPROVEMENT.md` §3/§4/§5 把 **提权触发（UAC / `osascript` / `AuthorizationServices` / `sudo` / `pkexec`）**
  与 `drop_caches`（需 root）列为能力，并建议核心逻辑用 **Kotlin Multiplatform（JVM）** 承载。
- **冲突**：与 `AGENTS.md`「运行期一律不得请求提权…需要提权才能实现的能力**放弃或降级**」及
  `CONTRIBUTING.md` §2.2「禁止非 FFI 大运行时（Node/Python/**JVM**）」直接冲突；
  更新稿 `docs/MEMORY_AND_TRIMMING_DEEP_DIVE.md` §4.4/§7 已明确「本项目无提权面…不引入系统级 purge / 提权」。
- **影响**：文档自相矛盾；若照旧稿实施即破红线，且 GUI 运行期弹 UAC / sudo / pkexec 属高风险设计（也违反「不做请以管理员身份运行的设计」）。
- **修复方向**：移入 `docs/archive/` 或在文首加 `SUPERSEDED`，注明被 `MEMORY_AND_TRIMMING_DEEP_DIVE.md` 取代。

### SEC-29 · 平台能力外观文档与现行架构 / 红线冲突

- **现象**：`docs/platform-capability-facade.md` §4 仍写「纯 Dart 可行的能力（D-Bus、GeoClue）用 Dart 包 + 条件导入……
  建议走自有原生模块或**插件通道**」；而 §7.3/§7.4 已改为「原生模块（Zig/C++）+ `dart:ffi`，零 JSON、零子进程」，
  且 `AGENTS.md` 明确「禁止 Dart 直调平台 API、不得 MethodChannel / 平台插件、不得 `Process.run`」。
- **影响**：同一文档前后矛盾，易误导新贡献者走已被禁止的「纯 Dart + 插件通道」路线。
- **修复方向**：§4 按 §7.3 修订或标注「已被 §7.3/§7.4 取代」。

### SEC-30 · `SystemLocation` 敏感权限缺授权语义

- **现象**：`docs/platform-capability-facade.md` §2.1/§3 登记 `SystemLocation`（GeoClue2 / Windows Location / CoreLocation），
  落地状态「后置」；文档只给接口与降级，未给「用户显式授权 / 可关闭 / 仅限声明用途 / 不做二次利用」的权限门禁。
- **冲突**：`CONTRIBUTING.md` §2.5 要求定位等敏感权限必须走能力外观层且满足上述约束。
- **影响**：若落地时未按权限纪律实现，将与 §2.5 及 `AGENTS.md`「最小权限（普通用户可完成）」冲突。
- **修复方向**：落地前补权限申请与可关闭语义；无能力平台保持空实现（§3 已定的静默降级）。

### SEC-31 · deep link 与 `apl_reveal_path` 外部输入校验未声明

- **现象**：`docs/platform-native-bridge.md` §3.1——`archoera://` 协议注册（免提权）+ `apl_deep_link_take/forward` 接收**外部 URI**；
  `apl_reveal_path(path)` 把路径交由 `org.freedesktop.FileManager1` / `SHOpenFolderAndSelectItems` / `ShellExecute` / `NSWorkspace` 处理；
  托盘图标路径由 Dart「落临时文件」后传入原生。
- **影响**：本机任意程序（含浏览器）可触发 `archoera://`；若 URI / 路径未做白名单与规范化，可能越权定位/打开任意路径，
  或经 `ShellExecute` 触发目标类型问题。
- **修复方向**：文档明确输入契约（仅识别自有 deep link 形式；reveal 仅接受应用内已解析的本地路径、拒绝远程/可执行目标）；
  原生侧对 scheme/host/path 做校验。

### SEC-32 · Subsonic 认证与传输模式未定义

- **现象**：`architecture.md` §7（Subsonic 走 Go FFI）与 `privacy.md` §5.2（仅笼统「目标支持时优先 HTTPS/TLS」）
  均未说明客户端对自建服务器采用 **token 认证（`t=md5(pw+salt)`）还是明文密码（`p=`）**，以及 http:// 服务器是否拒绝 / 警示。
- **影响**：若以明文密码经 HTTP 传输，凭据在链路上可被嗅探；自建服务器常为内网 http。历史评分件亦提到「支持明文密码、无哈希」。
- **修复方向**：文档明确认证模式与「不支持 HTTPS 时的行为 / 警示」；优先 token 认证。

### SEC-33 · 下载临时文件与已存在同名路径（符号链接）处理未定义

- **现象**：`download-module.md` §3.3 `tmpPath = destPath + ".tmp"`、完成后原子 rename；§v0.3 提到崩溃后清理 `*.tmp`；
  `sanitize` 仅替换非法字符并做 "(1)(2)" 去重，未声明对**已存在同名符号链接 / 非普通文件**的处理。
- **影响**：下载目录若为多用户可写或存在预置符号链接，写 `.tmp`（若跟随链接打开）可能写到预期外路径；同名追加逻辑不区分文件类型。
- **修复方向**：写临时文件用 `O_NOFOLLOW|O_CREAT|O_EXCL`、写入前后校验路径类型、rename 前确认目标非目录/符号链接；文档补契约。
- **置信度**：文档层推断（需代码确认打开方式），严重度低。

### SEC-34 · 多运行时同进程的信号处理器 / 全局符号冲突

- **现象**：`module-on-demand-load-plan.md` §2 显示同进程并存 Go runtime / .NET NativeAOT（scanner、vault）/
  Rust tokio（downloader / transcoder）/ Zig 内核 / FFmpeg；sqlite 以 `RTLD_GLOBAL|DEEPBIND` 预加载；
  `audio-kernel-zig.md`（2026-10-02）记录了 `std.Io.Threaded.deinit` 恢复旧 `SIGIO` handler **致进程被信号终止**的真实缺陷；
  vault 文档亦记录 NativeAOT 接管 `SIGSEGV`。
- **影响**：多个运行时各自安装信号处理器 / 全局符号，dlopen/dlclose 顺序可能引发进程终止或符号错绑（DoS / 稳定性）；
  `DEEPBIND` 在 glibc 文档中属「不推荐使用」。
- **修复方向**：文档补「多运行时信号 / 符号共存」风险与约定（谁安装 / 还原 handler、避免 `RTLD_GLOBAL`/`DEEPBIND`、按需加载只做已验证模块）。

---

## 8. 已文档化、无需重复的风险（对照）

vault 文档已明确声明，故不重复登记：L1 静态文件窃取、L2 同用户恶意进程、L3 离线爆破、L4 信任根攻破、
OS 份额覆盖、vault 文件 DoS（`VaultLimits`）、uid 路径遍历（锚点）。

---

## 8.5 第八批 · 红队复验证据（2026-10-12）

方法与边界：本地 Linux 原生 + `msvc-wine`/Wine（真实 Windows 产物）+ macOS SDK 交叉编译；
仅在本机用户自有数据上做**非破坏性**验证（临时目录、探针二进制不入库）。

**撬开的路径（修补前实测）**：

| # | 手段 | 结果 |
|---|---|---|
| W1 | 非 vault 二进制直接 `CryptUnprotectData(<dataDir>/sshare.bin)` → 取 `ShareBundle` 偏移 6 起的 32B 主密钥 → Node `aes-256-gcm` 直解 `credentials.vault` | **成功**读出条目明文（不碰官方 vault、不碰口令、不走血缘/握手） |
| W2 | `OpenProcess(PROCESS_VM_READ)` + `ReadProcessMemory` 遍历活动会话内存 | 命中主密钥 4 处、凭据明文 1 处、base64 3 处、`get` 响应串 2 处、**已删除条目 base64**（一次运行命中） |
| X1 | `.tmp`/`.bak` 预置为符号链接 | 覆盖任意用户文件（canary 被写）；`.tmp` 场景 vault 文件被替换为符号链接（后续读写被重定向） |
| X2 | `.tmp` 预置为 FIFO | `set` 后 12s 无响应且进程存活——保存路径**永久阻塞**（写路径无超时） |
| L4 | 每次猜测前删除 `vault.lockout` | 12 次错误口令 0.93s（≈13 次/秒）无锁定（对照：有退避时 5 min/次，约 2 个数量级差距；属**已声明**残余） |

**修补后复验**：W1 仍成立（属 SEC-39 同用户边界，应用层不可封闭）；W2 的**已删除凭据残留降为 0 命中**、
凭据明文 0 命中、`get` 响应串 0 命中（仅主密钥仍在会话内存中——`mlock` 防换页不防读）；X1/X2 **全部被拒**
（`err 拒绝写入：…非普通文件`，canary 未被覆盖、vault 保持普通文件、FIFO 不再挂死）；L4 不变（已声明残余）。

**反向发现（文档可收紧）**：Linux 侧 `PR_SET_DUMPABLE=0` 实测**强于**`vault-security-notes` 的表述——
`ptrace`/`process_vm_readv` 返回 `EPERM`、`/proc/<pid>/{mem,maps,smaps,environ}` 返回 `EACCES`（该表述原是
针对 Dart 主进程的）。

**沙箱完整性（第八批复验）**：

- **逐条生效性**：不只「过滤器是否装载」，而是对 denylist **每一条**被拒系统调用各 fork 一个子进程实际调用，
  内核以 `SIGSYS` 终止才算生效 —— `archoera-vault selftest-seccomp list` 实测 `killed=33/33 failed=-`
  （名单漂移 / 内核 ABI 差异会在该项暴露）；回归在 `test.sh` §13.2。
- **覆盖所有命令**：SEC-41 修复后，`main` 入口即 `harden_process()`（mlock 配额 / `RLIMIT_CORE=0` /
  `PR_SET_DUMPABLE=0` / seccomp / Windows 缓解）。实测一次性命令（`set-kdf`）采样：
  `Seccomp: 2`、`/proc/<pid>/mem` `EACCES`、`Max core file size 0`；回归 §13.1。

**「打爆沙箱是否会让 vault 自毁」——实测结论：不会**（回归 §13.3/§13.4）：

| 打击方式 | 结果 |
|---|---|
| 活动会话 SIGKILL / SIGTERM / SIGSEGV | 凭据仍在、仍可解锁；**不产 core**（`RLIMIT_CORE=0` + `dumpable=0`） |
| seccomp 违例（AF_INET socket → SIGSYS 自杀） | 数据未动 |
| 篡改 / 截断 / 垃圾化 vault 文件 | `serve` 被拒，**文件未被删除**；复原后凭据完好 |
| 篡改 / 删除 `device.key`（m2a/m2b） | 被拒或引导恢复码，**文件未被删除**；复原后可解锁 |
| 篡改 `secret.key`（file 后端） | 被拒，文件未删除 |
| `LD_PRELOAD` 注入 | 拒绝运行，数据未动 |
| 重复 `init-*`（回滚路径） | 被拒，既有 vault 未被误删 |
| **显式 `destroy`**（对照组） | 目录清空 —— **唯一**的数据销毁入口 |

配套（应用层，[vault_process.dart](../app/lib/services/security/vault_process.dart)）：非预期退出只写 `crash`
标记并 `exit(86)` 终止**主进程**（fail-closed），版本异常只删除**二进制副本**，二者都不触碰凭据数据；
`data_destroyer.dart` 仅由安全设置面板按钮调用（用户显式动作）。

**沙箱被破坏的语义（SEC-42，第八批定稿）**：

| 类别 | 例子 | 行为 |
|---|---|---|
| **可观测的蓄意破坏** | 加载器注入变量（`LD_PRELOAD`/`LD_AUDIT`/`DYLD_INSERT_LIBRARIES`）；seccomp 违例（内核 `SIGSYS`） | vault **自毁**（退出码 87 / 信号）→ 应用 crash 标记 → `exit(86)` **连带主程序退出**，默认路径二进制副本一并删除 |
| **不可观测的攻破** | 同用户 `ptrace` / 读 `/proc/<pid>/mem` | **不做检测**（内核层已拒绝、vault 无从感知；猜测式检测只会误报且拦不住真攻击）——防线是 `PR_SET_DUMPABLE=0`/`mlock`/静态链接 |
| **数据完整性失败** | vault/`device.key` 被篡改、截断、垃圾化 | **只拒绝本次操作**（不联动、不删除）：可能是磁盘损坏，升级则会成为「丢个坏文件就让应用自杀」的 DoS 原语 |
| **任何情况** | — | **绝不删除用户凭据**；销毁只有显式 `destroy`（或设置面板）一条路径 |

**App 层文件访问（SEC-47，本轮收口）**：新增 `app/lib/utils/safe_file.dart` ——
**读**要求「必须是普通文件」（`allowSymlink` 默认 true 以兼容把配置软链到 dotfiles 的用户，
可显式关闭）+ 长度上限（拒绝超大文件 OOM）；**写**走「同目录随机唯一临时名 → `rename`」，
使符号链接**只被替换、不被穿透**（此前 `writeAsStringSync` 会顺着链接覆盖目标，
`data_destroyer` 的覆盖写更会把目标文件抹掉）；擦除器增加「仅普通文件」前置判定，
`openSync` 型流式写先删同名路径再创建并不跟随校验。
残余（如实）：纯 Dart 回退路径下 `dart:io` 无 `O_NONBLOCK`/`O_NOFOLLOW`，判定与读写之间有极窄 TOCTOU 窗口
（需精确抢时）。**已落地**：平台桥接新增原生 `open(2)` 安全文件能力（`APL_CAP_SECURE_FILE`，ABI v4：
`apl_file_read`/`apl_file_write_atomic`，`O_NOFOLLOW`/`O_NONBLOCK` + 打开后按句柄 `fstat` 判普通文件；写走独占
临时名 + rename），能力可用时 `SafeFile` 自动切到原生后端，彻底关闭该窗口（见 docs/platform-native-bridge.md §3.2.1）。

**并发语义（SEC-46，定稿「兼容并发」）**：不使用「最后写者获胜」（会静默丢更新）。写命令以
**阻塞式跨进程独占锁**（`flock`/`LockFileEx`，内核唤醒、非轮询）保护「加载 → 改 → 保存」：
多会话仍可交错执行（锁范围=单条命令），拿不到锁时在内核等待，**崩溃自动释放**，无陈旧锁；
锁文件 `vault.lock` 永不删除（内容为空、非敏感面）。注意：握手路径的「取/建锚点」也取一次锁，
故外部长期持锁会连带阻塞握手（受调用方超时约束）。

**读写两侧的对称防护（收尾复查）**：写入侧统一 `O_CREAT|O_EXCL` 独占 + 进程唯一 tmp + 拒绝非普通文件
（SEC-37/38/45）；读取侧统一 `read_regular_limited`（拒绝符号链接/FIFO/目录 + **读前**按元数据判长度，
SEC-44）；容量上限在**写入前**校验（SEC-43）。三者共同消除「植入一个文件即可挂死/自锁/vOOM」这一类。

**字节兼容锚点变更**：C# 版删除后，活体 oracle（互解互读）替换为**冻结黄金夹具**
（`app/core/vault-rs/testdata/`；`test.sh` §14 + `test-windows.sh` §11 读回固定值）——比活体实现更稳、不需 .NET。

**环境限制（如实标注）**：Wine 的 `CryptProtectData` 为固定密钥实现——换 `WINEPREFIX` 仍能解封同一
`sshare.bin`，故 Wine 上的 DPAPI **不能**用于验证「用户绑定」；真机需复验（SEC-39 中「同用户任意进程可解封」
的结论不依赖 Wine，来自「无 `pOptionalEntropy` → 仅绑定 OS 用户」的 API 语义）。

---

## 8.6 第九批 · 红队复验（2026-10-14）：宿主进程未硬化 → core 泄露明文凭据（SEC-48）

**授权背景**：维护者在自备机器上、以自己的账号登录流媒体后，授权对 vault 做同用户「撬锁」复验
（目标：从 **m2a**（口令 + `device.key` + 恢复码）容器里取出明文凭据）。**全程本机、只读式尝试、不外传、真实密钥不外泄**。

**结论**：vault 本体（容器格式 / Argon2id / 沙箱 / 血缘校验 / 退避）**没有被绕过**；
最短路径落在**宿主进程**——它必须持有已解密的凭据，却没有做进程硬化。

**复现（同用户，无需口令 / 设备因子 / 恢复码；也无需 ptrace）**

```bash
pid=$(pgrep -x archoera_music)          # 应用宿主进程
kill -SEGV "$pid"                       # 同用户可对自身进程发信号；内核据 core_pattern 产 core
coredumpctl dump "$pid" -o /tmp/core    # systemd-coredump 落盘并对属主附加可读 ACL
# 或直接读 /var/lib/systemd/coredump/core.<name>.1000.*.zst（ACL: user:<uid>:r--）
grep -a -oE 'MUSIC_U=[^;]{6,}' /tmp/core
```

**实测结果（脱敏）**：core 内命中 **`MUSIC_U=00C…`、`__csrf=b07…`、`_ntes_nuid=afc…`** 等明文
（应用进程 RSS 仅 ~307 MiB，core 16 MiB 即够）。即：**m2a 的三因子被整体绕过**；
且 core **落盘**使泄露超出进程生命周期（退化为 L1 磁盘取证 / 备份泄露）。
对照：vault 子进程本就硬化（`PR_SET_DUMPABLE=0` + `RLIMIT_CORE=0`）——缺的是**持有明文的宿主**。

**修复（同批落地）**：平台桥接新增 ABI `apl_harden_process()`，三端后端实现：

| 平台 | 措施 |
|---|---|
| Linux | `setrlimit(RLIMIT_CORE, 0)`（本进程 + 子进程继承）→ 禁 core |
| macOS | `setrlimit(RLIMIT_CORE, 0)` → 禁 core |
| Windows | 关闭 WER 崩溃转储/错误框（`SetErrorMode` + `WerSetFlags(NO_UI)`，best-effort） |

Dart 侧在 `PlatformBindings.tryLoad()` 里 `apl_init` 成功**后立即**调用（早于任何凭据进入内存）；
**release 构建生效**（debug 保留调试/产核能力，避免阻碍开发）。

**复验（A/B 对照，决定性）**：`bash -c 'ulimit -c 0; kill -SEGV $$'` → `coredumpctl` 状态 **`none`**
（"terminated abnormally **without generating a coredump**"）；对照组 `ulimit -c unlimited` → **`present` 56K**
（"dumped core"）。即 `RLIMIT_CORE=0` 对**管道式** `core_pattern`（systemd-coredump）同样生效，应用进程同样观测到
`without generating a coredump`。注意 `coredumpctl list` 的**条目数会 +1**（那是一条**无内容**的日志记录，
status 列为 `none`），不能只看条数——须看 `info` 的 size/message。

**首版矫枉过正与撤回（同日回归 → 修正）**：首版同时设了 `PR_SET_DUMPABLE=0`（macOS 为 `PT_DENY_ATTACH`），
实测**打断 vault 的父进程血缘校验**——vault 在打包布局下要读 `/proc/<ppid>/exe` 与预期主程序比对，而
`dumpable=0` 让**子进程**也读不到父进程的 `/proc/pid/exe`（内核 `ptrace_may_access` 语义；最小复现：
父进程 `PR_SET_DUMPABLE=0` 后 `fork()`，子进程 `readlink("/proc/<父pid>/exe")` → `EACCES`），
于是握手报 `独立运行被拒：无法读取父进程可执行文件路径`，**凭据库整体不可用**（登录态无法持久化）。
故最终形态**只保留禁 core**：core 落盘是本次实测**唯一**能真正绕过 vault 的持久化路径，且与血缘校验无冲突；
同用户直接读内存（`ptrace`/`process_vm_readv`/`/proc/pid/mem`）属 **SEC-25 已声明残余**（Linux 侧由
`kernel.yama.ptrace_scope=1` 阻断、macOS 侧由 `task_for_pid` 默认需 root/entitlement 阻断，无法在普通用户
权限内强制，尤其 `ptrace_scope=0` 的发行版）。**结论：安全机制之间不能互相拆台**——加固不得使既有防线失效。

**第二轮复验（2026-10-14，登录态下重新撬锁）**：加固后按同一路径重打 ——
`kill -SEGV` 后 `systemd-coredump` 明确记 **"terminated abnormally without generating a coredump"**，
`/var/lib/systemd/coredump` **无文件**、`coredumpctl dump` 仅回 994B **元数据记录**（已扫描：无凭据特征）✓；
`/proc/<pid>/mem` 与 `process_vm_readv` 被内核拒（`kernel.yama.ptrace_scope=1`）✓；
`/proc/<pid>/environ`/磁盘/日志/prefs 均无明文 ✓；MCP（keyless）工具面无凭据通道
（`get_preferences` 对含 `key/secret/token/password/cookie/credential` 的键一律剔除）✓。
**意外发现（非漏洞、但文档定性偏高）**：vault 的**进程血缘校验可被绕过** —— 把 `archoera-vault`
复制到非 `native/` 目录即按 "dev/测试布局" 跳过校验（实测）；但**因子仍挡住**（无口令/恢复码
报 `m2a 需要 handshake <口令>`）。故已在 credential-vault-plan §3.5 把「双因子：进程血缘 + 主密钥持有」
更正为「纵深两层，真正的门＝主密钥持有」，与代码注释一致。

**残余（如实声明）**：

1. **同用户运行期注入仍是硬上限**（SEC-25 已声明）：能 `LD_PRELOAD`/替换二进制/在加固前取得执行权的攻击者，
   仍可在硬化的进程内读内存——加固消除的是「**已退出进程的磁盘快照**」与「**非父进程 ptrace**」两条**可避免的放大器**。
2. **同用户读内存（Linux `ptrace_scope=0` / 无 Yama 的发行版）**：未设 `PR_SET_DUMPABLE=0`（见上「撤回」），
   该路径依赖内核 `kernel.yama.ptrace_scope=1`；建议发行版/文档引导用户保持默认 1（我们无权修改系统 sysctl）。
3. **Windows 无 Linux `PR_SET_DUMPABLE` 等价物**：转储是否落盘取决于系统 WER 策略（best-effort 抑制，非强制）。
4. **debug 构建不硬化**：生产（release）路径生效；对 debug 产物的取证不在威胁模型内。
5. **辅助进程**：子进程 fork 继承 `RLIMIT_CORE=0`；vault 另行自硬化。Dart `String` 不可 zeroize（SEC-03 残余）仍在。

**同批附带复验（低危，纵深）**：MCP 控制服务 `mcp.allowKeyless=true` → 本机任意进程可无密钥读库/控制播放
（Playback/库统计实测可读）。浏览器侧已由 **Origin allowlist** 挡住（伪造 `Origin: https://evil.example` → 403），
但 **Host 未校验**（`Host: evil.example.com` 仍 `200`）——DNS rebinding 的前置条件。建议：默认关闭 keyless，
并校验 `Host` 属于本机白名单（纵深防御，非阻塞项）。

---

## 8.7 第九批随访（2026-10-14）：方案切换的「新库口令对不上」丢库风险

**现场（维护者本机实测）**：m2a 方案一次切换后，用户输入口令解锁持续报
`SHARE_MISMATCH AES-256-GCM 认证失败`，最终触发退避锁定。取证：容器在切换时刻被**重新初始化**
（2535B→322B、新 `vault_id`/`device.key`/锚点/标记，槽=口令+设备 / 恢复码，条目=1），
`prefs.security.scheme=m2a`、`m2aRecoveryAcked=true` —— 即**切换成功执行完**（旧库按设计被销毁，
切换对话已明示），但**新库的口令与用户以为的不一致**（或用户未改用新口令）。

**机理**：切换流程是「快照 → `destroy`（旧库/份额一并销毁）→ `init` 新方案 → `discard` 快照」。
初始化成功后**没有任何验证**证明「新库能被刚输入的口令解开」；一旦不一致，旧库已销毁 →
只能靠 m2a **恢复码**（`HKDF(恢复码, salt, RECOVERY_INFO)`，**不依赖口令与 `device.key`**，
见 `vault-rs/src/service.rs` m2a `rec` 分支 + 单测「device.key 丢失后恢复码解锁」）或重建。

**修复**（同批落地）：
1. `VaultProcess.verifyUnlock(dataDir, password:)`：`init` 成功后**立即用刚输入的口令做一次真实解锁往返**；
   失败 → 抛错 → 现有 `catch` 回滚快照（**旧库原封不动**，并提示「已回滚，旧库未动」）。
2. 顺序改为 **`setCredentialScheme` → `discard`**：即使中断/崩溃也不会留下「容器是新的、pref 是旧的」。
3. 回归：`vault_process_v4_test.dart`「verifyUnlock 自验证：正确口令通过 / 错误口令抛错」。
4. 恢复码仍是最后兜底（界面已有「用恢复码解锁」入口，`VaultUnlockGate`）。

**残余**：`destroy` 删除的**系统钥匙串份额**（crypto 模式）仍在进程外、无法随快照回滚——故 crypto
切换前置 `canInitCrypto()` 预检（临时目录探测，不触碰真实库）；其余方案的 `destroy` 均在快照内可回滚。

---

## 9. 修复批次建议

| 批次 | 目标 | 建议纳入 |
|---|---|---|
| 第一批（文档澄清，低成本） | 修正定性、补声明、消矛盾、清过时稿 | SEC-04、SEC-07、SEC-14、SEC-15、SEC-17、SEC-18、SEC-19、SEC-20、SEC-28、SEC-29 |
| 第二批（凭据面统一） | 消灭第二套密钥 / 明确降级边界、内存驻留 | SEC-01、SEC-02、SEC-03 |
| 第三批（防护加固） | 可绕过点与 DoS | SEC-05、SEC-06、SEC-08、SEC-09、SEC-34 |
| 第四批（功能面加固） | 输入 / 网络 / 权限面 | SEC-10、SEC-11、SEC-12、SEC-13、SEC-16、SEC-30、SEC-31、SEC-32、SEC-33 |
| 第五批（发布供应链） | CI / 签名 / 溯源（优先级高，牵涉信任根） | SEC-21、SEC-22、SEC-23、SEC-24、SEC-25、SEC-26、SEC-27 |
| 第八批（vault 回归 + 文件系统面 + App 层收口） | 内存护栏 / zeroize / 安全落盘 / 沙箱覆盖 / 容量·读侧·并发 / App 文件访问 | SEC-35～SEC-38、SEC-41～SEC-47（SEC-39 为已声明残余；SEC-40 复核撤回） |

> 完成任一项后：把 §1 台账对应行「状态」改为「已修复（版本 / 提交）」，并在相关规范文档同步修订。
