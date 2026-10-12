# 安全评审问题台账（2026-10-11）

> 状态：**修复中**——第一批（文档澄清，SEC-04/07/14/15/17/18/19/20/28/29）已完成（364cd5b）；其余待修复。
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
| SEC-01 | 高 | 第二套密钥体系 `secret.key` + `user.db` `enc:v1:` 未纳入 vault | architecture §8；credential-vault-plan §3.1/§4 | ❌ 未提 | 待修复 |
| SEC-02 | 高 | v4-file 单因子 + `ARCHOERA_VAULT_SECRET_KEY` 主密钥走 env | vault-scheme-comparison §1/§4；vault-security-notes | ❌ 未提 | 待修复 |
| SEC-03 | 高 | 启动预取全量明文常驻 Dart 内存，与「用后即弃」矛盾 | credential-vault-plan §8.2 | ❌ 未提 | 待修复 |
| SEC-04 | 高 | PROD marker 被当作「二进制替换主防线」，实为可伪造字符串 | credential-vault-plan §3.8/§8.4；vault-security-notes §二进制替换防护 | ⚠️ 高估 | 已修复（文档·第一批，364cd5b） |
| SEC-05 | 中 | `vault.lockout`/`vault.auth`/`vault.marker` 同用户可写 → 退避 / 锚点 / 崩溃标记可绕过 | credential-vault-plan §8.4；vault-security-notes §份额覆盖 | ❌ 未提 | 待修复 |
| SEC-06 | 中 | Argon2id KDF 参数无加载上限 → 解锁前内存 / CPU DoS | credential-vault-plan §5/§8.6 | ❌ 未提 | 待修复 |
| SEC-07 | 中 | `ARCHOERA_VAULT_PARENT_OK` 由发起方注入 → 血缘 + 握手可自造绕过 | credential-vault-plan §3.8/§8.4 | ⚠️ 高估 | 已修复（文档·第一批，364cd5b） |
| SEC-08 | 中 | FFI 库 / 二进制加载顺序劫持（按文件名 + 系统搜索路径） | ffi-libs-layout-plan（Dart 路径解析）；vault-security-notes §二进制替换防护 | ❌ 未提 | 待修复 |
| SEC-09 | 中 | 全链路日志无脱敏，vault stderr 转发入明文日志 | unified-logging §2/§3；archive/robustness-improvement-plan §2 | ❌ 未提 | 待修复 |
| SEC-10 | 中 | MCP 密钥明文落盘；局域网模式为明文 HTTP | mcp §1/§5 | ❌ 未提 | 待修复 |
| SEC-11 | 中 | 下载 / 整理的文件路径由元数据派生，`subDir` 未清洗 `..` | download-module §3.3；local-library §刮削 | ❌ 未提 | 待修复 |
| SEC-12 | 中 | 原生 HTTP 客户端重定向未限制降级 / 内网 / 非官方主机 | audio-kernel-zig（2026-10-01 / 2026-10-07 落地） | ❌ 未提 | 待修复 |
| SEC-13 | 中 | 设备指纹与项目自身红线（CONTRIBUTING §2.5）冲突 + 隐私政策未披露 | CONTRIBUTING §2.5；device-bound-vault-plan §5.1；downloader-identity-plan §3.1；privacy §二 | ❌ 未提 | 待修复 |
| SEC-14 | 低 | vault 安全声明 env 清单不完整 | vault-security-notes §测试明文存储/§二进制替换防护 | — | 已修复（文档·第一批，364cd5b） |
| SEC-15 | 低 | OS 份额共享只写「应用副本覆盖」，未写「第三方应用可读」 | vault-security-notes §份额覆盖风险 | ❌ 未提 | 已修复（文档·第一批，364cd5b） |
| SEC-16 | 低 | 迁移 / 模式切换跨存储的崩溃一致性未列风险 | device-bound-vault-plan §8；credential-vault-plan §3.4 | ❌ 未提 | 待修复 |
| SEC-17 | 低 | architecture 内部残留（`sessions` 表已废弃 vs cookie 落点） | architecture §7.4/§8 | — | 已修复（文档·第一批，364cd5b） |
| SEC-18 | 低 | 归档评分件与现行口径不一致（明文密码 / 无哈希 / GetUsers） | archive/archoera-robustness-score §6 | — | 已修复（文档·第一批，364cd5b） |
| SEC-19 | 低 | 测试后门 `ARCHOERA_VAULT_INSECURE_FILE_STORE` 无删除里程碑 | vault-security-notes §测试明文存储 | ⏳ 已声明计划 | 已修复（文档·第一批，364cd5b） |
| SEC-20 | 合规 | 声明禁止绕过访问控制，实现却利用服务端 UA 旁路 | software-declaration §五；neko-source-identity；audio-kernel-zig 2026-10-07 | ❌ 未提 | 已修复（文档·第一批，364cd5b） |
| SEC-21 | 中 | GitHub Actions 依赖按可变主版本标签固定、未 pin SHA（含签名作业） | build-all.yml；actions/build-linux | — | 待修复 |
| SEC-22 | 中 | 关键路径无强制评审（`protect-main` Required approvals=0，CODEOWNERS 不生效） | .github/CODEOWNERS；AGENTS.md §仓库保护 | — | 待修复 |
| SEC-23 | 高 | 发版 tag 可指向未评审提交 → CI 构建并签名攻击者代码 | build-all.yml（`on.push.tags`+release 构建 `github.ref`） | — | 待修复 |
| SEC-24 | 中 | 标签名直接内插进 shell（`${{ github.ref_name }}` 命令注入反模式） | build-all.yml:990 | — | 待修复 |
| SEC-25 | 中 | 无构建溯源 / SBOM；macOS 仅 ad-hoc、Windows 未签名（信任根承诺未兑现） | sign_release.sh；build-all.yml（ad-hoc 注释） | — | 待修复 |
| SEC-26 | 中 | 无依赖漏洞扫描（无 dependabot / 各生态 audit） | .github；robustness-improvement-plan §3-12 | — | 待修复 |
| SEC-27 | 中 | CI 测试面过窄（仅 widget/vault 冒烟，非全量） | actions/build-linux §Test | — | 待修复 |
| SEC-28 | 中 | 过时设计稿主张运行期提权 + JVM 核心（违反红线） | CROSS_PLATFORM_CAPABILITY_IMPROVEMENT.md | — | 已修复（文档·第一批，364cd5b） |
| SEC-29 | 低 | 平台能力文档与现行架构/红线冲突（纯 Dart/插件通道 vs 原生桥接） | platform-capability-facade.md §4 vs §7.3 | — | 已修复（文档·第一批，364cd5b） |
| SEC-30 | 低 | `SystemLocation` 敏感权限缺授权/可关闭语义 | platform-capability-facade.md §2.1/§3 | — | 待修复 |
| SEC-31 | 中 | deep link 与 `apl_reveal_path` 外部输入校验未声明 | platform-native-bridge.md §3.1 | — | 待修复 |
| SEC-32 | 中 | Subsonic 认证/传输模式未定义（token vs 明文密码、http vs https） | architecture §7；privacy §5.2 | — | 待修复 |
| SEC-33 | 低 | 下载临时文件与已存在同名路径（符号链接）处理未定义 | download-module.md §3.3 | — | 待修复 |
| SEC-34 | 低 | 多运行时同进程的信号处理器/全局符号冲突（DoS/稳定性） | module-on-demand-load-plan.md §2；audio-kernel-zig 2026-10-02 | — | 待修复 |

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

### SEC-04 · PROD marker 被高估为「二进制替换主防线」

- **现象**：文档把握手应答尾部 `BuildInfo.Marker`（PROD/TEST 指纹）称为二进制替换防护的**第二道（协议内）防线**，
  并在默认路径下「缺失或非 PROD → 杀进程 + 删副本 + fatal 态」。
- **证据**：`credential-vault-plan` §3.8、§8.4；`vault-security-notes.md` §二进制替换防护；`CONTRIBUTING.md` §10「PROD marker 双重校验逻辑不得削弱」。
- **影响**：marker 只是**字符串指纹，无签名 / 无认证**。攻击者可自行编译含后门的 vault 并输出同名 `ARCHOERA-VAULT-PROD-*`，
  同时通过 `--version` 与握手校验；`ARCHOERA_VAULT_BIN` 显式指定（notes §二进制替换防护）更直接跳过 PROD 校验。
  故该机制只能防「误用测试构建」，**不能防「替换二进制」本身**——与文档「主防线」定性不符。
- **修复方向**：修正文档定性为「防测试构建误用」；真正的二进制完整性需 OS 代码签名 / 安装包完整性清单（§8.5 已列待办）落地后承接。

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
- **SEC-16** 迁移 / 模式切换的崩溃一致性：`device-bound-vault-plan` §8 与 `credential-vault-plan` §3.4 的
  「先落份额后写 vault，失败回滚」跨**两个存储**，单文件原子替换**覆盖不到两步之间被 kill**；可能留下不可解 vault（丢登录态），风险表未列。
- **SEC-17** `architecture.md` 内部残留：§7.4 仍说 cookie 走「Dart 本地层 + vault」、logout 清 `sessions` 表，
  而 §8 说 `sessions` / `downloads` 表方案已废弃 → 易误读 cookie 实际落点。
- **SEC-18** 归档件 `docs/archive/archoera-robustness-score.md` §6 的「支持明文密码、无哈希 / GetUsers 无权限检查」与
  现行 `architecture.md` §8 的 `enc:v1` 口径不一致（历史件，易被误引用）。建议在归档目录标注其时效。
- **SEC-19** `ARCHOERA_VAULT_INSECURE_FILE_STORE` 测试后门「待删除」（`vault-security-notes.md` §测试明文存储）无删除里程碑；
  建议在本文档登记一个目标版本 / 触发条件（Linux keyring CI 基建就绪）。

---

## 5. 声明与合规冲突（非内存漏洞）

### SEC-20 · 声明禁止绕过访问控制，实现却利用服务端 UA 旁路

- **现象**：`software-declaration.md` §五 写明「请勿绕过在线平台的技术保护措施、访问控制或服务条款」；
  但实现文档记录：**复用官方客户端 UA 形状**通过 `isNativeClient` 锚定、并利用服务端「空 UA 直接放行」旁路清空 UA。
- **证据**：`neko-source-identity.md`（身份头方案与「不变量」）；`audio-kernel-zig.md`（2026-10-07 头透传与空 UA 修正）。
- **影响**：与本软件自身用户声明相冲突，属披露 / 合规风险（非本地漏洞）。
- **修复方向**：如实调整声明措辞或改用服务端认可的自报标识（`X-Neko-Client` 正向放行）；
  文档明确「版本锚定形状仅通过正则锚定，不冒名品牌」的边界与风险。

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

### SEC-25 · 无构建溯源 / SBOM；macOS 仅 ad-hoc、Windows 未签名

- **现象**：release 作业仅用 key1 对已下载 artifact 签 `.sig1`（`app/tool/sign_release.sh`），无 provenance/SBOM；
  macOS 构建注释明确 **ad-hoc 签名**（`CODE_SIGN_IDENTITY = "-"`），未见 Windows Authenticode。
- **影响**：`.sig1` 只证明「该 key 签了这份字节」，不证明构建来源 / 可复现；
  而 vault 文档（§1.2-5、§信任根边界）把 L4 信任根寄托于「OS 信任链（Authenticode / 公证 / 安装包完整性）」——**发布产物当前并未签名 / 公证，该承诺尚未兑现**。
- **修复方向**：接入 `actions/attest-build-provenance` 与 SBOM；落地 Windows 代码签名、macOS 公证；
  并在 vault 文档把该项标为「未完成」，避免读者误判。

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

## 9. 修复批次建议

| 批次 | 目标 | 建议纳入 |
|---|---|---|
| 第一批（文档澄清，低成本） | 修正定性、补声明、消矛盾、清过时稿 | SEC-04、SEC-07、SEC-14、SEC-15、SEC-17、SEC-18、SEC-19、SEC-20、SEC-28、SEC-29 |
| 第二批（凭据面统一） | 消灭第二套密钥 / 明确降级边界、内存驻留 | SEC-01、SEC-02、SEC-03 |
| 第三批（防护加固） | 可绕过点与 DoS | SEC-05、SEC-06、SEC-08、SEC-09、SEC-34 |
| 第四批（功能面加固） | 输入 / 网络 / 权限面 | SEC-10、SEC-11、SEC-12、SEC-13、SEC-16、SEC-30、SEC-31、SEC-32、SEC-33 |
| 第五批（发布供应链） | CI / 签名 / 溯源（优先级高，牵涉信任根） | SEC-21、SEC-22、SEC-23、SEC-24、SEC-25、SEC-26、SEC-27 |

> 完成任一项后：把 §1 台账对应行「状态」改为「已修复（版本 / 提交）」，并在相关规范文档同步修订。
