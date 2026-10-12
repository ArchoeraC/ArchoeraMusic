# 凭据保险库安全说明

凭据保险库（`app/core/vault`）对登录会话与流媒体服务器密码做 2-of-2 加密存储。以下说明对**测试后门**与**发布产物边界**作出声明，请勿在生产环境启用任何测试开关。

> **安全漏洞请走私密渠道报告**（[SECURITY.md](../SECURITY.md)），禁止公开 Issue / PR / Discussion 讨论漏洞细节。
> 设计与实施细节见 [credential-vault-plan.md](credential-vault-plan.md)。
> **已知缺口与待修复项**见 [security-review-2026-10-11.md](security-review-2026-10-11.md)（本文档的补强台账）。

## 测试明文存储（仅限调试，后期删除）

- `ARCHOERA_VAULT_INSECURE_FILE_STORE=1` 是**测试专用明文存储开关**（份额明文落盘，非真实安全等级），仅存在于**测试构建**：
  - 由 `app/core/vault/build-test.sh`（`#if VAULT_TESTING` 条件编译）产出 `archoera-vault-test`，仅用于本地调试与 CI（headless 无 D-Bus Secret Service 时验证完整加解密链路）；
  - **生产构建** `app/core/vault/build.sh` 产物 `archoera-vault` **不编译该逻辑**——即使设置该环境变量也无法启用明文存储（可对发布产物执行 `strings -el` 验证无 `ARCHOERA_VAULT_INSECURE_FILE_STORE`）；
  - **该测试后门计划在 Linux keyring CI 基建完善后删除**（届时测试改用真实 OS 安全存储）。
    **删除里程碑（SEC-19）**：触发条件 = Linux keyring（Secret Service + 无头 D-Bus）CI 基建就绪、`archoera-vault-test` 不再依赖明文存储即可跑通全链路；达成后移除 `VAULT_TESTING` 分支与 `InsecureFileStore`，本行随之删除。在此之前，该开关**仅存在于测试构建**、**绝不进入发布产物**。
- 测试产物 `archoera-vault-test` **绝不进入发布产物**（bundle / 安装包 / release artifact 均不含，打包流程无引用）。

## 构建标记校验（防「误用测试 / 构建」混入）

> **定性**：本节机制只是**构建自报指纹校验**，用于防止**误用测试构建**，**不是**「二进制替换防护」——marker 是可自报的字符串（无签名 / 无认证），攻击者可自行编译输出 `ARCHOERA-VAULT-PROD-*` 的后门 vault 通过校验；真正的二进制完整性依赖 OS 信任链（Authenticode / 公证 / 安装包完整性清单），当前发布产物**尚未**签名 / 公证（见 [security-review SEC-25](security-review-2026-10-11.md)）。

- **双重校验（fail-closed）**：
  1. **加载前校验**：`archoera-vault --version` 输出 `ARCHOERA-VAULT-PROD-*` 才允许解析默认路径二进制；
  2. **握手内 marker 校验**：每次 serve 会话的握手应答尾部携带构建标记 `BuildInfo.Marker`（PROD/TEST 版本指纹）。主程序解析应答第 5 字段——默认路径解析的 vault 必须为 PROD 标记，**缺失或非 PROD（即携带 `ARCHOERA_VAULT_INSECURE_FILE_STORE` 显式启动指令的测试构建）→ 杀进程 + 删除默认路径副本 + 拒绝解密 + 置版本异常 fatal 态**，UI 顶层 `VaultVersionGate` 全屏拦截，**仅允许用户退出**（不提供销毁/重试等继续操作）；
- 该机制可拦截**被替换为官方测试构建**（含明文存储后门）的情形：应用不会加载它，即便绕过加载前 `--version` 校验，握手阶段 marker 校验仍会拒绝并删除副本——**但仅限「原样替换为官方 TEST 产物」**；攻击者**自行编译**一个照旧输出 PROD marker 的后门二进制时，本机制**无法识别**（见上方定性）；
- `ARCHOERA_VAULT_BIN` 仅作为显式信任边界供测试/CI 使用（设置进程环境本身即需系统权限，生产路径绝不设置）：env 显式指定的二进制跳过 PROD 校验（信任边界），但 marker 存在性仍校验（防旧版协议误判）。

## 信任根边界（威胁模型声明）

- **应用层防线覆盖范围**：爆破主密钥（→ 2-of-2 + Argon2id + 退避锁定）已纵深防护；**替换 vault 二进制**仅能靠构建标记拦截「原样换成官方 TEST 产物 / 缺 marker」的情形，**不能拦截自行编译的后门二进制**（见「构建标记校验」定性）；
- **同用户攻击者不在防线内**：血缘校验的白名单 `ARCHOERA_VAULT_PARENT_OK` 由调用方注入、握手密钥 `H/C` 也由调用方自选，同用户攻击者可自行 spawn vault 复现握手——血缘 / 握手只防「无主进程上下文的误用与自动化」，**不防同用户进程**；
- **边界**：信任根在主程序进程。攻击者**同时替换主程序（Dart 可执行 / FFI 库）** 或**在其内嵌主动联网上传程序段**时，vault 视主进程为合法握手对象、无法区分被篡改的主程序——此威胁（进程注入 / 信任根攻破）**超出应用层能力**，由 OS 信任链承担：Windows Authenticode 签名 / macOS 公证 / 安装包完整性校验（**当前发布产物尚未签名 / 公证**，见 [security-review SEC-25](security-review-2026-10-11.md)；已列入 credential-vault-plan 待办）；
- 本方案无法承诺具有拦截「同用户权限下完全控制进程 / 按源码重实现的攻击者」的能力（Kerckhoffs 原则，见 [credential-vault-plan §1.2](credential-vault-plan.md)）。

## 份额覆盖风险与恢复（OS 安全存储全局共享）

- **现象**：解锁报 `The computed authentication tag did not match the input authentication tag`，应用降级为内存态（日志「凭据保险库不可用，登录态将不持久化」），功能可用但重启需重新登录。
- **根因**：OS 模式（v1）下授权侧份额 S 存于 OS 安全存储（Linux Secret Service / macOS Keychain / Windows DPAPI），**存储键全局共享、无 per-app 隔离**（Linux 为 schema `archoera.vault` / account `master-share`）。同一设备上**任何一份应用副本**（安装包 / 开发 bundle / CI 产物）在 vault 未初始化时执行 `init` 都会**覆盖**该份额——若 vault 文件与份额不同代（例如更新前初始化、之后另一副本再次 `init` 覆盖份额），即出现上述解锁失败；**覆盖不可逆，旧份额无法找回，旧登录态不可恢复**。
- **同样适用于第三方应用**：该全局条目**无应用隔离**——同机上**任意第三方应用**（同用户、有 OS 安全存储访问权）同样**可读 / 可覆盖** S；配合可读到的 `credentials.vault`（见 §信任根边界：同用户进程不在防线内），攻击者可解出凭据。macOS 若以 `kSecClassGenericPassword` 未设 ACL、Windows 若无额外访问控制，同理；**份额共享的隔离强度取决于 OS 钥匙串，而非本应用**。
- **恢复**：删除应用数据目录下的 `credentials.vault`（及同目录 `vault.lockout` / `vault.auth` 残留），应用下次启动自动初始化全新 vault——**旧登录态丢失，需重新登录各平台账号**；或直接执行 `archoera-vault destroy <数据目录>`（一并删除份额与锁定状态）后重启应用。
- **数据目录**：Linux `~/.local/share/ArchoeraMusic`；macOS/Windows 见应用数据目录（路径解析见 `resolveDataDir()`）。
- **避免**：勿在同一设备上同时运行多份不同数据目录的应用副本并各自初始化；升级/替换安装包前如需保留登录态，**不要删除 vault 文件**，并避免在新副本上触发重新初始化。

## 环境变量与信任边界（完整清单）

> 本节完整声明所有影响安全面的 `ARCHOERA_VAULT_*` 环境变量及其信任边界（此前文档只列了部分，SEC-14）。**生产路径不得设置除 `ARCHOERA_VAULT_PARENT_OK`（由主进程自动注入）以外的任何变量**。

| 环境变量 | 作用 | 信任边界 / 影响 | 生产 |
|---|---|---|---|
| `ARCHOERA_VAULT_INSECURE_FILE_STORE=1` | 测试专用明文存储（份额明文落盘） | 仅存在于**测试构建**（`VAULT_TESTING` 条件编译）；生产构建不编译该逻辑，设置亦无效 | ❌ 不设置 |
| `ARCHOERA_VAULT_BIN` | 显式指定 vault 二进制路径 | 显式信任边界：**跳过默认路径的 PROD 校验**（marker 存在性仍校验）；能设置进程环境即属调用方权限 | ❌ 不设置 |
| `ARCHOERA_VAULT_BACKEND=file` | 选择 **v4-file** 后端（单因子、主密钥整体落盘 `secret.key`） | **弱化**等级：单文件密钥泄露即凭据全泄露，弱于 v1 OS 存储（见 §已知缺口 SEC-02） | ❌ 不设置 |
| `ARCHOERA_VAULT_SECRET_KEY` | ~~覆盖 v4-file 主密钥 K~~ | **已移除**（SEC-02）：改为 `init-file --key-stdin`（stdin 首行 hex64，不经 argv/env）；env 会出现在 `/proc/<pid>/environ`（同用户可读），故不再支持 | ⛔ 已移除 |
| `ARCHOERA_VAULT_FINGERPRINT` | 覆盖 v3 设备指纹（`machine-id` / `MachineGuid` / `IOPlatformUUID`）来源 | 影响设备绑定份额的派生输入（见 §已知缺口 SEC-13） | ❌ 不设置 |
| `ARCHOERA_VAULT_PARENT_OK` | 血缘白名单（逗号分隔可执行名） | **由调用方（主进程）注入，可被自造** → 血缘 / 握手**不防同用户攻击者**（SEC-07） | ✅ 主进程自动注入 |
| `ARCHOERA_VAULT_NO_ABORT=1` | 崩溃联动测试豁免（仅写 `vault.marker`，不 `exit(86)`） | 测试专用；设置后崩溃不在主进程侧 fail-closed | ❌ 不设置 |

## 已知安全边界与缺口（如实声明）

以下为**文档层评审已登记**的边界 / 缺口，本文档如实声明，**勿视为已防护项**（其中 SEC-04 / SEC-07 的**表述定性已修正**，SEC-01 已纳入 vault、SEC-06 已加固，其余为待修复项）。完整台账（含证据、影响、修复方向、状态与批次）见
[security-review-2026-10-11.md](security-review-2026-10-11.md)：

- **Subsonic 用户密码已纳入 vault**（SEC-01，**已修复**）：用户密码不再以 `database/user.db` 的 `enc:v1:` 字段级加密 +
  `dataDir/secret.key` 自举为唯一保护，而是经 vault 统一持久化（uid=`subsonic:<username>`，Dart `VaultSubsonicCredentialStore`）；
  `password_cipher` 仅空串占位，服务端认证经 `archoera_subsonic_set_credentials` 注入内存凭据表。
  旧库 `enc:v1:` 密码在 `SubsonicAdmin.open` 时解密迁入 vault（成功才置空该列，失败保留待重试）。
  注：`secret.key` 与 v4-file 主密钥文件**同名且为同一文件**，现仅服务 vault file 模式；Subsonic 凭据不再依赖它（2026-10-12 修复）；
- **v4-file 模式与主密钥 env**（SEC-02）：v4-file 为单因子（K 落盘 `secret.key`），选用即显式降级；
  原 `ARCHOERA_VAULT_SECRET_KEY` **env 注入已移除**，改为 `init-file --key-stdin`（不经 argv/env）——
  与 [credential-vault-plan.md](credential-vault-plan.md) §3.8「argv / 环境不携带任何凭据」一致；
- **启动预取常驻明文**（SEC-03，**已知接受项**）：Dart 侧 `StreamingStore.preloadSecrets()` 启动即解密全部流媒体凭据常驻内存，
  且 Dart 字符串不可 zeroize、不受 mlock 保护；缓解为主进程 `PR_SET_DUMPABLE=0` + `RLIMIT_CORE=0`（不覆盖同用户读 `/proc/<pid>/mem`）；
- **PROD marker 定性过高**（SEC-04）：marker 为可伪造字符串，只能防「误用测试构建」，**不能防替换二进制本身**；
- **lockout / auth / marker 同用户可写**（SEC-05）：`vault.lockout` 可删（重置退避）、`vault.auth` 可随 vault 一并替换（锚点失效）、
  `vault.marker` 可伪造（DoS 或掩盖崩溃）——**已如实声明：这些文件不构成对同用户攻击者的防线**（加固待办：状态移入 OS 安全存储 / HMAC 绑定 / 防伪造）；
- **KDF 参数加载上限**（SEC-06，**已修复**）：头部与封装块的 Argon2id `m / t / p` 现经 `VaultLimits.ValidateKdf` 解析校验（`m ≤256 MiB / t ≤16 / p ≤8`），越界在派生前快速拒绝（`InvalidDataException`），
  `ReadHeader`（握手前）与 `Load`（解锁）均覆盖，`Argon2id.Derive` 另设同上限纵深防御；头部参数被篡改只会派生错误 S（条目 AEAD 认证失败），不泄露数据（2026-10-12 修复，回归 `test.sh` 第 21 项）；
- **血缘 / 握手不防同用户**（SEC-07）：`ARCHOERA_VAULT_PARENT_OK` 由发起方注入，可自造通过。
