# 凭据保护方案比对：vault 新容器 vs 业界通用方案

> 2026-10-12（2026-10 重构后重写） · 关联规划：[credential-vault-plan.md](credential-vault-plan.md) · [vault-enhanced-scheme.md](vault-enhanced-scheme.md)
> ⚠️ 已知缺口与待修复项见 [security-review-2026-10-11.md](security-review-2026-10-11.md)（含 file 单因子声明缺口 SEC-02、应用层信任根 SEC-08/SEC-25）。
> **重构说明**：旧的 v1（OS 2-of-2）/ v2（口令）/ v3（设备密封多封装）/ v4-file 分层已**移除**，统一为
> **crypto（默认，`'C'`）** 与 **slots（`'S'`）容器（m1 / m2a / m2b）**；旧 vault 文件报「vault 版本不兼容」，无迁移。
> 目的：明确我们的实现对业界常见凭据保护方案的「优势 / 问题」，供安全决策与演进参考。

## 1. 方案速览

| 代号 | 方案 | 密钥/解锁因子模型 |
|---|---|---|
| **crypto** | OS 安全存储 / 文件密钥（默认，`'C'`） | 主密钥 K 整体存 OS 安全存储（libsecret/DPAPI/Keychain）或 `file` 后端 `secret.key`（0600）；vault 文件不含密钥材料；**单因子**。OS store 键按数据目录作用域 |
| **slots-m1** | 口令模式（`'S'`，kind=1） | KEK = Argon2id(口令, salt, ad=vaultId‖kind) 封装 K；口令不落盘、经 stdin 握手传入；自包含、无 OS 钥匙串 |
| **slots-m2a** | 口令+设备双因子 + 恢复码（`'S'`，kind=4 + kind=3） | KEK = HKDF(Argon2id(口令)‖deviceSecret)；`deviceSecret` 存本地 `device.key`(0600)；恢复槽由一次性高熵 Crockford-Base32 恢复码解锁 |
| **slots-m2b** | 设备单因子（**本机级 · 较弱**，本机免密，`'S'`，kind=2） | KEK = HKDF(deviceSecret)；仅需**同用户可读**的 `device.key`，无口令、无恢复槽；读到 `device.key` + vault 即离线全解 |
| A | OS 原生钥匙串直存 | macOS Keychain / Windows DPAPI / Linux libsecret 直接存凭据明文 |
| B | 主密码加密库 | KeePass / Bitwarden 本地库 / LastPass 本地——单一主密码派生 KEK 加密整个库 |
| C | 云密码管理器 2-factor | 1Password（Secret Key + 主密码）/ Bitwarden（服务器 + 2FA）——服务器侧托管密文 |
| D | 硬件绑定 | TPM 密封 / Android Keystore / YubiKey HMAC——密钥不脱离硬件 |
| E | 基线 | 明文文件 / 环境变量 / 硬编码 |
| F | 纯 crypto 库自封装 | Web Crypto / libsodium / ring / pointycastle 等标准原语直拼——AES-GCM / Argon2id 加密落盘，**密钥自管理**（硬编码 / 环境变量 / 裸存 keyring），无配套协议 |

## 2. 威胁模型分级

| 级别 | 攻击者能力 | 示例 |
|---|---|---|
| L1 | 静态文件窃取 | 备份泄露、磁盘克隆、恶意软件只读 |
| L2 | 本机恶意进程 | 同用户下的恶意进程、被注入的主程序 |
| L3 | 在线泄露 / 暴力破解 | 云端密文拖库、离线跑口令 |
| L4 | 信任根攻破 | 同时替换主程序 + FFI 库 / 内嵌主动联网上传段 |

## 3. 逐维度对比矩阵

| 维度 | crypto | slots-m1 | slots-m2a | slots-m2b | A 钥匙串 | B 主密码库 | C 云 2FA | D 硬件 | F 纯 crypto |
|---|---|---|---|---|---|---|---|---|---|
| 静态密钥不落地 | ⚠️ K 存 OS store（不落 vault 文件）；file 后端 K 落盘 `secret.key` | ✅ 口令派生不落盘 | ✅ 口令+设备熵，双因子 | ⚠️ 无口令，device.key 落本地 | ❌ 直接存明文 | ⚠️ 密文+单 KEK | ⚠️ 密文+双因子 | ✅ 硬件不导出 | ⚠️ 看 key 来源（硬编码❌ / 裸 keyring 单点） |
| 解锁因子数 | 1（OS store / 文件） | 1（口令） | 2（口令 + device.key；恢复码兜底） | 1（device.key） | 0（OS 直接） | 1（主密码） | 2（SecretKey+主密码） | 1（硬件在场） | 0-1（随 key 来源） |
| 抗 L1 文件窃取 | ⚠️ OS 模式文件本身无 K；file 模式拿 `secret.key` 即破 | ✅ | ✅ 缺 device.key 或口令不可解（vault 文件不含 deviceSecret） | ⚠️ 拿到 `device.key` + vault 即可解 | ❌ 拿库即明文 | ⚠️ 可离线爆破主密码 | ✅ 服务器侧 | ✅ | ❌ key 与库同机即全破 |
| 抗 L2 恶意进程 | ⚠️ 父进程身份校验，主程序内被注入仍可能 | ⚠️ 同左 | ⚠️ 同左 | ⚠️ 同左 | ❌ OS 服务代答 | ❌ 进程内即得 KEK | ⚠️ 取决于客户端隔离 | ✅ 强 | ❌ 进程内解密，无边界 |
| 抗 L3 离线爆破 | ✅ OS 模式无口令面；file 模式无口令面 | ⚠️ Argon2id 防 GPU 但单因子；KDF 参数有上下限且强度用户可选 | ✅ 需同时破口令与窃取 device.key | ⚠️ 无口令面，但 `device.key` 被窃即全破（**本机级 · 较弱**，非密码学边界） | — | ⚠️ PBKDF2/Argon2 可跑 | ✅ 服务器限流+2FA | ✅ | ⚠️ 自研 KDF/限流缺位，可无限跑 |
| 丢失恢复 | ⚠️ OS store / 文件丢失即重置 | ⚠️ 忘口令→重置重建 | ✅ 恢复码（device.key 丢失时） | ⚠️ device.key 丢失→重置重建 | ✅ OS 账户即恢复 | ⚠️ 忘主密码→丢失 | ✅ 恢复码 | ⚠️ 丢硬件→丢失 | ❌ 通常无恢复设计 |
| 平台依赖 | ⚠️ 三平台 keyring ABI；file 后端纯文件 | ✅ 纯 BCL | ⚠️ 依赖本地 `device.key` 文件（尚未接入 OS 钥匙串） | ⚠️ 同左 | ⚠️ 平台专属 API | ✅ 纯文件 | ✅ 跨平台 | ⚠️ 平台专属 | ✅ 跨平台 |
| 可销毁性 | ✅ 删文件 + 清 OS store / `secret.key` | ✅ 删文件即可 | ✅ 删文件 + `device.key` + `.bak` | ✅ 删文件 + `device.key` + `.bak` | ⚠️ 依赖 OS 清理 | ✅ 删库 | ⚠️ 服务器残留 | ⚠️ 硬件密钥无法删 | ⚠️ 取决 key 存放 |
| 进程边界/内存 | ✅ 独立进程+mlock+握手 | ✅ | ✅ | ✅ | ❌ 无（调用方进程） | ❌ 无 | ⚠️ 客户端进程 | ✅ 硬件内 | ❌ 无 |

## 4. 各方案优势与问题

### vault crypto（OS 安全存储 / 文件密钥，默认，单因子）
- **优势**：稳定性最高——无份额配对、无口令、无设备熵，不存在「份额丢失导致凭据整体丢失」（旧 v1 的痛点）；OS 模式下 vault 文件不含密钥材料，窃取文件无法解密；解锁零摩擦；OS store 键按数据目录作用域，修复跨目录覆盖。
- **问题**：**单因子**——OS 钥匙串被攻破 / `file` 后端 `secret.key` 泄露即凭据全泄露（弱于旧 v1 的 2-of-2）；依赖三平台 keyring ABI 行为差异（Linux 已按 gnome-keyring / KDE 两种 `CreateItem` 形态兼容，见下）；`file` 后端为显式降级（headless / Docker）。
- **Linux 后端（2026-10-14 补实现）**：`crypto` 的 OS 后端在 Linux 走 **Secret Service（libsecret / `org.freedesktop.Secret`）**，由 vault-rs **纯 Rust 直连 D-Bus** 实现（`app/core/vault-rs/src/secret_service.rs`，无新依赖；seccomp 沙箱本就按地址族放行 `AF_UNIX`，未改沙箱）。条目 `xdg:schema = archoera.vault` + `account = "{key}|{dataDir}"` 与 C# 时代**逐字一致**（老条目可读、不产生「新老各一份」）；兼容 KDE ksecretd/kwalletd 偏离规范的 `CreateItem(a{sv} properties, (oayays) secret, b replace)`（先按规范签名调用，`UnknownMethod`/`InvalidArgs` 时回退——libsecret 亦做同层兼容）；`prompt = "/"` 按规范视为「无需交互」。无 D-Bus、钥匙串锁定需交互、服务拒绝 → 一律 **fail-closed 报错，不静默降级为 `file`**。真机端到端：`ARCHOERA_SECRET_SERVICE_E2E=1 cargo test --bin archoera-vault e2e`（无桌面钥匙串自动跳过）。
- **残余（SEC-15）**：Secret Service 对**同会话内的应用没有客户端侧 ACL**——任何同会话应用都能经 D-Bus 读/写该集合（除非钥匙串守护进程自身要求解锁/授权）。这是平台边界，客户端无法收紧；故 Linux 上 `crypto` 的 OS 存储同样**只算纵深防御的一层**，不能对抗同用户恶意进程。

### vault slots-m1（口令模式）
- **优势**：纯 BCL 零外部依赖、跨平台一致、**自包含**（换机复制文件 + 口令即可解）；口令不落盘不落 argv（stdin 握手）；Argon2id 抗 GPU 爆破且 KDF 参数有上下限；尾部 HMAC verify-before-decrypt；锁定退避阻断在线爆破。
- **问题**：单因子——口令弱则全破；忘口令=数据不可解（无恢复）；口令输入面（键盘记录属于信任根范畴）。

### vault slots-m2a（口令 + 设备双因子 + 恢复码）
- **优势**：双因子——离线攻击需同时破口令**且**窃取 `device.key`；恢复码提供可恢复性（`device.key` 丢失时兜底），优于 m1 的无恢复；vault 文件不含 deviceSecret（熵材料独立存 `device.key`）。
- **问题**：`device.key` 与 vault 文件同机被拷且攻击者持有口令时即失守；恢复码仅初始化输出一次，**当前无「重新生成恢复码」命令**，丢失无法补发；三端 `device.key` 尚未接入 OS 钥匙串（仅 0600 文件）。

### vault slots-m2b（设备单因子，本机级 · 较弱）
- **优势**：本机零交互免密；无口令面可爆破。
- **问题**：**无口令、无恢复**——安全级别等同 `device.key` 的存储强度（本地 0600 文件被窃即失守，且**同用户可读**：实测仅凭 `device.key` + vault 文件即可离线解出全部明文）；`device.key` 丢失即重置重建；须显式告警其弱于 m2a（**本机级 · 较弱**），**推荐 m1/m2a**。

### F 纯 crypto 库自封装（开发者常见做法：Web Crypto / libsodium / ring / pointycastle 直拼）
- **优势**：标准原语久经验证（AES-256-GCM / Argon2id / HMAC 与 vault 同级）；跨平台；无外部服务依赖。
- **问题**：**密钥管理自决**——硬编码 / 环境变量 / 裸 keyring 均为单点，任一泄露即全破；无解锁退避（离线可无限爆破）；进程内解密无边界（被注入即得明文）；无篡改检测 / 无 fail-closed / 无可销毁保证；丢失无恢复设计。vault 与它的差别不在算法（相同原语），而在把**密钥生命周期、调用边界、崩溃响应固化为协议**（§5-2）。

### A OS 钥匙串直存（对比基线之上限）
- **优势**：零实现成本、OS 级隔离（DPAPI/Keychain 有账户绑定）。
- **问题**：**拿库即明文**（无加密分层）；无进程边界；无 fail-closed；无篡改检测；可销毁性依赖 OS 清理——这正是我们弃用「裸存」的原因。

### B 主密码加密库（KeePass/Bitwarden 本地）
- **优势**：实现简单、社区久经验证、主密码即全部。
- **问题**：单 KEK 单因子——主密码泄露=全破；离线爆破仅靠 KDF 强度；进程内解密无边界；无丢失恢复。

### C 云密码管理器 2-factor（1Password 等）
- **优势**：Secret Key 式 2 因子协同（与 m2a 同构）；服务器侧密文抗本地窃取；恢复体系成熟。
- **问题**：**服务器是信任第三方**（拖库+端点攻击风险）；依赖账号体系与网络；我们定位本地单机，不引入服务器信任面（m2a 的双因子 ≈ Secret Key 的本地等价物）。

### D 硬件绑定（TPM/Keystore/YubiKey）
- **优势**：密钥永不离开硬件，抗 L2/L4 最强。
- **问题**：平台专属 API 差异大、可移植性差；硬件丢失=数据丢失；实现成本高——作为 P2 演进候选（`device.key` / 主密钥 mlock→硬件密封），当前未落地。

## 5. 结论与边界

1. **定位**：crypto / m1 / m2a / m2b 是「本地密码管理器」范畴的方案——在**无服务器**前提下，m2a 达到近似云 2FA 的因子结构（双因子 + 恢复），并叠加密码管理器通常没有的**进程边界 + fail-closed + 篡改检测**。
2. **核心差异 vs 通用方案（含纯 crypto 库）**：crypto 库与通用方案解决「加密运算」——算法层大家相同（AES-256-GCM / Argon2id / HMAC）；我们解决「密钥不落地 + 谁有权调用 + 被攻破如何响应」三个工程问题。纯 crypto 自封装（F）把这三个问题全部留给开发者自决，正是自研加密存储最常见的失败点。
3. **信任根边界（L4）**：vault 全部防线建立在「主程序可信」前提上——主程序+FFI 库同时被替换/内嵌上传时，任何本地方案（含 B/C 客户端）都无法防御。**OS 代码签名（Authenticode / 公证）当前不推进**，故应用层以 **key1 签名的原生完整性清单**为真实性机制（见 [vault-security-notes.md](vault-security-notes.md) §应用层信任根 / [supply-chain.md](supply-chain.md) §2），其残余硬上限**如实保留**。
4. **演进方向（按性价比）**：D 硬件绑定（TPM/Keystore）→ 密钥不落硬件；`device.key` 接入 OS 钥匙串；vault 核心未来可考虑以 **Rust 带外进程**重写（内存安全、无 CLR、可静态 musl 以收紧 seccomp allowlist，仍保持独立进程隔离）——均属未落地项。
