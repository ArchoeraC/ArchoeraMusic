# 凭据保险库安全说明

凭据保险库（`app/core/vault`）对登录会话与流媒体服务器密码做 2-of-2 加密存储。以下说明对**测试后门**与**发布产物边界**作出声明，请勿在生产环境启用任何测试开关。

> **安全漏洞请走私密渠道报告**（[SECURITY.md](../SECURITY.md)），禁止公开 Issue / PR / Discussion 讨论漏洞细节。
> 设计与实施细节见 [credential-vault-plan.md](credential-vault-plan.md)。

## 测试明文存储（仅限调试，后期删除）

- `ARCHOERA_VAULT_INSECURE_FILE_STORE=1` 是**测试专用明文存储开关**（份额明文落盘，非真实安全等级），仅存在于**测试构建**：
  - 由 `app/core/vault/build-test.sh`（`#if VAULT_TESTING` 条件编译）产出 `archoera-vault-test`，仅用于本地调试与 CI（headless 无 D-Bus Secret Service 时验证完整加解密链路）；
  - **生产构建** `app/core/vault/build.sh` 产物 `archoera-vault` **不编译该逻辑**——即使设置该环境变量也无法启用明文存储（可对发布产物执行 `strings -el` 验证无 `ARCHOERA_VAULT_INSECURE_FILE_STORE`）；
  - **该测试后门计划在 Linux keyring CI 基建完善后删除**（届时测试改用真实 OS 安全存储）。
- 测试产物 `archoera-vault-test` **绝不进入发布产物**（bundle / 安装包 / release artifact 均不含，打包流程无引用）。

## 二进制替换防护（防「测试/被替换二进制混入安装包」）

- **双重校验（fail-closed）**：
  1. **加载前校验**：`archoera-vault --version` 输出 `ARCHOERA-VAULT-PROD-*` 才允许解析默认路径二进制；
  2. **握手内 marker 校验（主防线）**：每次 serve 会话的握手应答尾部携带构建标记 `BuildInfo.Marker`（PROD/TEST 版本指纹）。主程序解析应答第 5 字段——默认路径解析的 vault 必须为 PROD 标记，**缺失或非 PROD（即携带 `ARCHOERA_VAULT_INSECURE_FILE_STORE` 显式启动指令的测试构建）→ 杀进程 + 删除默认路径副本 + 拒绝解密 + 置版本异常 fatal 态**，UI 顶层 `VaultVersionGate` 全屏拦截，**仅允许用户退出**（不提供销毁/重试等继续操作）；
- 即使攻击者通过木马等方式把预编译的测试二进制（含明文存储后门）下载并替换进应用安装包，应用**不会加载它**；即便绕过加载前 `--version` 校验，握手阶段 marker 校验仍会拒绝并删除副本——凭据无法被该后门读取；
- `ARCHOERA_VAULT_BIN` 仅作为显式信任边界供测试/CI 使用（设置进程环境本身即需系统权限，生产路径绝不设置）：env 显式指定的二进制跳过 PROD 校验（信任边界），但 marker 存在性仍校验（防旧版协议误判）。

## 信任根边界（威胁模型声明）

- **应用层防线覆盖范围**：仅替换 vault 二进制（→ 双重校验 fail-closed 删副本）、爆破主密钥（→ 2-of-2 + Argon2id + 退避锁定）——均已纵深防护；
- **边界**：信任根在主程序进程。攻击者**同时替换主程序（Dart 可执行 / FFI 库）** 或**在其内嵌主动联网上传程序段**时，vault 视主进程为合法握手对象、无法区分被篡改的主程序——此威胁（进程注入 / 信任根攻破）**超出应用层能力**，由 OS 信任链承担：Windows Authenticode 签名 / macOS 公证 / 安装包完整性校验（已列入 credential-vault-plan 待办）；
- 本方案无法承诺具有拦截「同用户权限下完全控制进程 / 按源码重实现的攻击者」的能力（Kerckhoffs 原则，见 [credential-vault-plan §1.2](credential-vault-plan.md)）。

## 份额覆盖风险与恢复（OS 安全存储全局共享）

- **现象**：解锁报 `The computed authentication tag did not match the input authentication tag`，应用降级为内存态（日志「凭据保险库不可用，登录态将不持久化」），功能可用但重启需重新登录。
- **根因**：OS 模式（v1）下授权侧份额 S 存于 OS 安全存储（Linux Secret Service / macOS Keychain / Windows DPAPI），**存储键全局共享、无 per-app 隔离**（Linux 为 schema `archoera.vault` / account `master-share`）。同一设备上**任何一份应用副本**（安装包 / 开发 bundle / CI 产物）在 vault 未初始化时执行 `init` 都会**覆盖**该份额——若 vault 文件与份额不同代（例如更新前初始化、之后另一副本再次 `init` 覆盖份额），即出现上述解锁失败；**覆盖不可逆，旧份额无法找回，旧登录态不可恢复**。
- **恢复**：删除应用数据目录下的 `credentials.vault`（及同目录 `vault.lockout` / `vault.auth` 残留），应用下次启动自动初始化全新 vault——**旧登录态丢失，需重新登录各平台账号**；或直接执行 `archoera-vault destroy <数据目录>`（一并删除份额与锁定状态）后重启应用。
- **数据目录**：Linux `~/.local/share/ArchoeraMusic`；macOS/Windows 见应用数据目录（路径解析见 `resolveDataDir()`）。
- **避免**：勿在同一设备上同时运行多份不同数据目录的应用副本并各自初始化；升级/替换安装包前如需保留登录态，**不要删除 vault 文件**，并避免在新副本上触发重新初始化。
