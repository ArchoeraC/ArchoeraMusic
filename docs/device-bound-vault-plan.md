# 设备绑定 Vault 规划（BitLocker 式多封装 · 增强型可选项）

> 状态：**实施中（第一步 vault 核心 v3 基础 ✅ + 第二步恢复口令管理 ✅ + 第三步 Dart 集成 · opt-in ✅ + 第四步迁移与设置页 ✅ + 第六步 v1↔v2 三档切换条 ✅，2026-08-13）** · 前提：credential-vault-plan（vault-1 ~ vault-4 + 口令模式 t9）已完成
> 定位（用户决策，2026-08-12）：**v3 设备绑定是增强型可选项（opt-in），默认仍为 v1（OS 模式）**——v1 对普通用户已足够，设备指纹采集涉及隐私且是「暴力增强」模块，选择权交给用户
> 方向确认：①自实现设备指纹绑定（不依赖 OS 安全存储）②v3 多封装 ③先定稿设计文档再分步实施
> 参考模型：BitLocker（TPM 自动解锁 + 恢复密钥）、Windows Hello / 系统凭据保险库（本机免密、设备变更走恢复）

## 1. 背景与目标

### 1.1 三个诉求（演进动机）

| 诉求 | 现状缺口 | 目标 |
|---|---|---|
| ① 口令验证是有条件的 | t9 口令模式每次会话需口令，若每日每操作都要求输入不可接受 | **日常（本机）完全免密**，口令仅在设备变更时出现 |
| ② 用户不该为音乐播放器记密码 | 口令是额外记忆负担 | 口令是**可选的恢复因子**，不是日常解锁因子；遗忘可销毁重建 |
| ③ 设备变更时能恢复 | OS 模式（v1）换设备 = OS 份额丢失 = 只能销毁重建重新登录 | **设备变更时经口令恢复**，凭据随迁移 |

### 1.2 BitLocker 模型（骨架）

```
BitLocker:   主密钥 VMK ── 封装① TPM 绑定   → 本机自动解锁（免密）
                        └─ 封装② 恢复密钥   → 硬件变更/克隆磁盘时手动恢复

本文档:      主密钥 K  ── 封装① 设备熵绑定  → 本机自动解锁（免密，零输入）
                        └─ 封装② 口令封装    → 设备变更/重装时手动恢复
```

「免密」与「恢复」是 **OR 关系**（任一封装成功即解锁），不是 AND——与 BitLocker 一致。

### 1.3 模式选择与隐私（用户 opt-in）

v3 涉及设备指纹采集（machine-id / MachineGuid / IOPlatformUUID，**仅本机读取、绝不上传**），
属隐私敏感项——作为**增强型可选项**，默认 v1（OS 模式）：

| 模式 | 定位 | 解锁交互 | 触发条件 |
|---|---|---|---|
| v1 OS 模式（默认） | 普通用户够用：OS 安全存储自动解锁 | 零交互（DPAPI/Keychain/libsecret） | 默认 |
| v2 口令模式（t9） | 无设备绑定 / 便携目录 | 每次会话输口令 | 用户选择 |
| v3 设备绑定（本方案） | 增强：本机免密 + 设备变更走恢复口令 | 本机零交互；换机一次性口令 | **显式 opt-in**（设置页开启，须确认隐私提示） |

**opt-in 落地约束**：
- 设置页开启 v3 时明确提示「将读取本机设备标识用于绑定，仅存本地，不上传」；
- 首次初始化引导默认选 v1，v3 为「高级」分支（折叠/次级入口）；
- 开启后可随时关闭（清除设备熵封装，回落 v1 语义或改纯口令）；
- 既有 v1 用户不受影响，升级路径可选（第四步迁移）。

## 2. 安全定位（开源约束认知）

软件级设备绑定**不可能做到 TPM 那样的硬件不可导出**：

- 设备指纹（machine-id / MachineGuid / IOPlatformUUID）是**可公开读取**的系统标识；
- 攻击者拿到 `credentials.vault` + `device.seal` + 指纹，按源码即可重建绑定密钥、解出熵 → 解密（与 downloader-identity 计划「盐混淆只防脚本小子」同一认知）。

因此**设备熵封装的真实价值是「迁移可用性 + 免密体验」，不是绝对机密性**：

| 防线 | 真正挡住什么 | 不挡住什么 |
|---|---|---|
| 设备熵封装（主路径） | 把 vault 文件拷到另一台机器直接解锁（换机无指纹） | 同机攻击者按源码逆向 |
| 口令封装（恢复路径） | 离线爆破（Argon2id memory-hard + 解锁失败退避） | 口令被键盘记录/钓鱼 |
| 2-of-2 骨架（K_vault ⊕ S） | 仅持 vault 文件 / 仅持封装任一侧 | 两侧同时在场是解密前提 |

高价值凭据仍建议叠加平台防线（OS 安全存储 / 系统账户边界），本方案是「默认免密 + 可恢复」的体验基线。

## 3. 架构总览：S 的多封装（v3）

```
credentials.vault（v3 多封装头）
  K_vault = K ⊕ S                          ← 2-of-2 骨架不变（KeySplit）
  S 的封装（任一方解出 S → K = K_vault ⊕ S）：
    封装① device.seal：seal(S, HKDF-SHA256(设备指纹, salt, info="archoera.device-entropy"))
                     └ AES-256-GCM，密钥=设备熵绑定密钥
    封装② vault 内嵌：seal(S, Argon2id(口令, salt, KDF 参数))
                     └ AES-256-GCM，密钥=口令派生密钥
```

- **解锁（本机）**：读设备指纹 → 解封 ① → 得 S → K。无口令、无交互、微秒级（一次 HKDF+AES-GCM，不跑 Argon2id）。
- **解锁（设备变更）**：解封 ① 失败（指纹不符/熵文件缺失）→ 落入口令路径 → 解封 ② → 得 S → K。
- **fail-closed**：①② 都失败 → 拒绝（锁定退避照常生效）；连续失败指数退避（复用 `Lockout.cs`）。
- **熵与口令的合成注意**：S 是随机生成的授权侧份额，**分别**被两种密钥密封（非「熵 ⊕ 口令」拼接）——两封装互相独立，任一路径可用即解锁（OR 语义），且口令封装不依赖熵封装的存在。

## 4. v3 文件格式

### 4.1 credentials.vault（v3 布局，向后兼容 v1/v2）

```
v1（OS 模式，不变）:
  magic "AVLT"(4B) | version(1B)=1 | reserved(3B) | key_vault(32B) | entries…

v2（口令模式，t9 已完成，不变）:
  magic "AVLT"(4B) | version(1B)=2 | kdf(1B)=1 | reserved(2B)
  | salt(16B) | m(u32) | t(u32) | p(u32) | key_vault(32B) | entries…

v3（多封装）:
  magic "AVLT"(4B) | version(1B)=3 | flags(1B) | reserved(2B)
  | key_vault(32B)
  | seal_count(u8)
  | seal[0]: kind(1B)=1(口令) | salt(16B) | m(u32) | t(u32) | p(u32)
             | nonce(12B) | ct_len(u32) | ciphertext(ct|tag)
  | seal[1]: kind(1B)=2(设备熵引用) | entropy_id(32B) | nonce(12B)
             | ct_len(u32) | ciphertext(ct|tag)
  | entries…
```

- `kind=1` 口令封装：KDF 参数随内嵌块存储（与 v2 同语义），密文 = AES-GCM(key=Argon2id(口令), pt=S)。
- `kind=2` 设备熵引用：**S 的密文不在 vault 文件内**，而指向 `device.seal` 的 `entropy_id`（32B 随机标识）；vault 内嵌 `seal(S, 熵密钥)` 的密文，`device.seal` 存熵本体（见 §5）。**熵本体与指纹绑定，绝不同时出现在 vault 文件**——拷贝 vault 文件不含熵，必须连 `device.seal` + 本机指纹一起才可解。
  - 实现简化：也可把熵封装直接内嵌 vault（kind=2 存 S 的熵密封密文），device.seal 只存熵 E 本身。解锁顺序：读 device.seal 熵 E → 指纹解封得熵密钥 → 解开 vault 内 kind=2 密文得 S。两种布局择一（倾向：**熵本体独立存 device.seal，S 的熵密封密文内嵌 vault**，破坏「单文件即解密」）。
- `ReadHeader` 对 v1/v2 保持现有解析；v3 新增 `VaultSeals` 元数据，模式判定扩展为 `MultiSeal`。

### 4.2 device.seal（熵文件，位于 dataDir，随 vault 共存）

```
magic "AVDX"(4B) | version(1B)=1 | kdf(1B)=1(HKDF-SHA256) | reserved(2B)
| entropy_id(32B) | salt(16B) | nonce(12B) | sealed_entropy(32B) | tag(16B)
```

- `sealed_entropy` = AES-256-GCM(key=HKDF-SHA256(设备指纹, salt, info="archoera.device-entropy"), pt=E)。
- **熵 E（32B）仅存在于解开后的锁定内存**（`LockedBuffer`，mlock + 用后 zeroize），不落盘明文。
- 熵绑定密钥**每次使用临时派生，不持久化**（防指纹公开后密钥长期有效）。

## 5. 设备指纹采集与熵绑定

### 5.1 指纹采集（三平台，纯 BCL / 最小平台调用）

| 平台 | 主指纹 | 备选（指纹漂移时降级） |
|---|---|---|
| Linux | `/etc/machine-id`（systemd）→ `/var/lib/dbus/machine-id` | hostname + `/proc/sys/kernel/random/boot_id` 组合 |
| Windows | `HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid`（Registry API） | 卷序列号（`GetVolumeInformationW`） |
| macOS | `IOPlatformUUID`（`ioreg -rd1 -c IOPlatformExpertDevice` 解析） | hostname + boot uuid |

- 指纹 = 主源成功则用主源，失败逐级 fallback；全部失败 → 视同「设备熵不可用」→ 仅口令路径（对用户表现为需口令）。
- 指纹归一化：直接取原始标识字符串，不 hash（HKDF 输入可变长，hash 反而引入碰撞/规范化问题）。
- **指纹漂移处理**（重装/系统更新导致 machine-id 变化）：设备变更检测命中后不静默重建——`entropy_id` 不变但解封失败 → 提示「设备标识已变化，输入口令恢复」（口令路径解出 S 后，可选「重新绑定当前设备」：用新指纹重密封熵）。

### 5.2 熵绑定密钥派生

```
K_entropy = HKDF-SHA256(IKM = 设备指纹, salt = 随机(16B, 随 device.seal 存储), info = "archoera.device-entropy", L = 32)
```

- HKDF 用纯 BCL `HKDF`（.NET 内置 `System.Security.Cryptography.HKDF`，NativeAOT 支持）。
- salt 每次绑定生成；重新绑定 = 新 salt + 新熵（或保留熵重密封）。

## 6. 恢复口令封装

- **设置**：`init-device <dataDir> [--set-recovery-password]`，口令经 stdin（不落 argv）；或首次启动引导时设置（可跳过）。
- **修改/清除**：会话内 `set-recovery-password` / `clear-recovery-password`（须先解锁，即持 K/S）。
- **遗忘口令**：与 v2 同代价——销毁重建（重新登录），明确提示。
- **纯口令模式（v2）保留**：作为「无设备绑定」选项（便携目录 / 多机共享数据目录 / 无稳定指纹环境）。v3 与 v2 并存：初始化时选择「设备绑定（免密，默认）」或「纯口令（t9）」。
- **可选增强（P2）**：敏感操作口令 gate——销毁/清除全部凭据前若设置了口令，要求输口令确认（对齐「口令验证是有条件的」：仅高危操作触发，日常操作永不触发）。

## 7. 会话层与 Dart 集成

### 7.1 日常免密（无会话令牌缓存）

BitLocker 式模型下「会话解锁」问题自动消失：

- 每次操作 spawn `serve` 会话 → 会话自动携带设备指纹（Dart 传 `ARCHOERA_VAULT_FINGERPRINT` 或经握手参数）→ vault 解封熵 → 解锁 → 命令 → quit。
- 解锁开销：一次 HKDF + AES-GCM（微秒级），**不跑 Argon2id** → 无性能/交互负担。
- 不需要「解锁令牌」「口令缓存」等会话状态——比 t9 的免密方案更简单（无需令牌 TTL/轮换/失效设计）。

### 7.2 设备变更检测与恢复流（Dart）

```
解锁请求 → vault 解封熵失败（fingerprint 不匹配 / device.seal 缺失）
        → serve 应答 err 携带码 `NEED_RECOVERY`
        → Dart 弹一次性口令输入（「设备标识已变更，输入恢复口令」）
        → 握手带口令 → vault 走口令封装 → 解锁成功
        → 可选：询问是否将当前设备设为信任设备（重密封熵）
```

- 错误码契约：`err NEED_RECOVERY <hint>`（hint 不含敏感信息）。
- 口令仅在恢复流输入一次；成功后可「重新绑定本机」免密继续。

### 7.3 设置页入口（P2 · opt-in）✅（2026-08-12 已随第三步落地）

- 安全页「高级 · 凭据加密」折叠区：**三档切换条**（v1 系统保护 / v2 口令保护 / v3 设备绑定）——取代原先单开关：
  - **v1 ↔ v2 可逆互切**（`switch-mode`，v1↔v2 切换条落地 ✅ 2026-08-13）：主密钥 K 不变、既有条目直接沿用（无需重加密），仅切换授权份额 S 的锚定（OS 安全存储 ↔ Argon2id 口令）；
  - v1 → v2：确认弹窗 + **新口令输入（含二次确认一致性校验）** → 切换后新口令即会话口令（本会话保持解锁）；
  - v2 → v1：确认弹窗 → `switch-mode os`（须本会话已解锁持口令）；
  - **v3 为终点档**：v1/v2 → v3 走「开启设备绑定」（显式隐私提示 → 可选恢复口令 → `init-device`/`upgrade-device`）；v3 → v2 走「关闭设备绑定」（输入当前恢复口令授权）；**v3 不可直接降回 v1**（点击 v1 档 toast 解释须先关闭设备绑定）；v2 未解锁时 v1/v3 档灰显（引导先经启动解锁门输入口令）；
- 开启 v3 后可管理：「设置/修改恢复口令」「重新绑定当前设备」「关闭设备绑定（清除熵封装）」；
- 设备变更/熵损坏时显示恢复横幅（一次性口令解锁 + 引导重新绑定）；
- 与既有「清除所有本地凭据」（destroy）并列；默认 v1，v3 显式 opt-in。

## 8. 兼容与迁移

| 场景 | 处理 |
|---|---|
| 既有 v1（OS 模式）| 设置页切换条手动升级（`upgrade-device`，第四步 ✅）：解锁后持 K → 生成熵 E → 写 `device.seal` + vault 升级 v3（kind=2 封装），可选补设恢复口令；**K 不变、既有条目直接沿用不重加密**；OS 份额仍保留 |
| 既有 v2（口令模式）| 启动解锁门输入会话口令解锁后，设置页切换条手动升级（`upgrade-device` 带会话口令）→ 补建熵封装升 v3；未升级仍按 v2 工作 |
| **v1 ↔ v2 互切**（v1↔v2 切换条 ✅ 2026-08-13）| 设置页切换条可逆互切（`switch-mode os\|password`）：**主密钥 K 不变、既有条目直接沿用不重加密**，仅切换授权份额 S 的锚定。v1 → v2 须设置新口令（Argon2id 派生 S，删除 OS 份额）；v2 → v1 须本会话已解锁（先落 OS 份额后写 vault，失败回滚）。多封装（v3）不可经此命令 |
| v3 熵文件损坏/缺失 | 落入口令路径；无口令封装 → 提示销毁重建 |
| 降级 | 设置页「关闭设备绑定」：输入当前恢复口令授权 → 清除熵封装回落 v2 口令模式（数据以新口令重加密保留）。**v3 为终点档：不可直接降回 v1**，须先回落 v2 |

- 迁移必须是「解锁成功后写回」：v3 写入前先完整校验（写临时文件 → 校验 → 原子替换），失败保留原文件。

## 9. 分步实施

1. **第一步（vault 核心，v3 基础）✅（2026-08-12）**：`Fingerprint.cs`（Linux machine-id / Windows MachineGuid / macOS IOPlatformUUID + 备选降级 + `ARCHOERA_VAULT_FINGERPRINT` 测试注入）+ `DeviceEntropy.cs`（熵生成/密封/解封 + HKDF + `SelfTest`）+ `VaultFile` v3 多封装头（`CreateMultiSeal`/`Seals`/`ReadHeader` 兼容 v1/v2）+ `VaultService.InitDevice`（熵封装 + 可选恢复口令）+ `LoadMasterKeyInto` MultiSeal 分支（熵路径/口令恢复路径/`NeedRecoveryException`）+ `ServeSession`（3/4 字段握手 + `err NEED_RECOVERY`）+ `Program init-device/status multiseal`；`selftest` 增加熵密封往返向量；test.sh 第 13 项全链路（本机免密 / 换机 NEED_RECOVERY / 恢复口令解锁 / 篡改 fail-closed / 错误口令锁定）。
2. **第二步（恢复口令管理）✅（2026-08-12）**：serve 会话内 `set-recovery-password <b64新口令>`（重密封 S，旧口令立即失效）/ `clear-recovery-password`（删除 kind=1，换机 fail-closed）/ `rebind`（当前指纹重密封熵，旧指纹失效）；`VaultFile.Save` 统一原子写（tmp + 替换）；test.sh 第 14 项全链路（改口令旧口令失效 / 新口令恢复 / rebind 新指纹免密旧指纹落恢复 / 清除后换机 fail-closed）。（注：`init-device --set-recovery-password` + NEED_RECOVERY 恢复流已随第一步落地。）
3. **第三步（Dart 集成 · opt-in）✅（2026-08-12）**：`VaultProcess` 增加 `initDevice`/`setRecoveryPassword`/`clearRecoveryPassword`/`rebind`/`clearDeviceSeal` + `VaultNeedRecoveryException` 分类；`VaultSessionStore`/`StreamingStore` 适配 v3 识别（`isDeviceBound`/`needsRecovery`/`recover()`，NEED_RECOVERY 与普通不可用区分）；设置页「高级 · 设备绑定」区（security_section.dart）：开关 + 显式隐私提示 + 可选恢复口令的 init-device；已开启后管理入口（设置/修改恢复口令、重新绑定、关闭设备绑定——关闭须输入当前恢复口令授权，回落 v2 口令模式）；设备变更恢复横幅（一次性口令解锁 + 引导重新绑定）；l10n 中英繁文案全量同步。验证：test.sh 15 项全绿（含新增 15 关闭设备绑定 + 15b 无口令被拒）+ flutter test 37 项（含新增 v3 Dart 测试：initDevice 本机免密 / 错误口令关闭被拒 / 正确口令关闭回落 password / device.seal 删除 / 数据以新口令回读一致）。
4. **第四步（迁移与设置页）✅（2026-08-12）**：`VaultService.UpgradeDevice`（v1/v2 解锁后持 K → 采集指纹 → 生成熵 E → 熵密封 S（kind=2）+ 可选口令封装（kind=1）→ `VaultFile.CreateMultiSeal`，**K 不变、既有条目直接沿用不重加密**；失败回滚删 `device.seal`；已 multiseal 拒绝）+ `ServeSession` `upgrade-device [--set-recovery-password <b64>]` 分发；Dart `VaultProcess.upgradeDevice`（v2 须传本会话口令）；`VaultSessionStore`/`StreamingStore` 支持 v2 口令模式（`needsPassword`/`unlockWithPassword`/`sessionPassword` 内存持有 + 持久化带口令；失败复位 `_vaultOk`/`_sessionPassword` 保持待解锁可重试）+ `StreamingStore.preloadSecrets` 口令模式置 `needsPassword` 而非误报 vault down；UI：`VaultUnlockGate` 启动解锁门（全屏口令页 → 解锁会话+流媒体凭据 → 刷新登录态+下载引擎，可「暂不解锁」跳过等同 v1 降级）挂载于 SplashGate 外层；设置页开关按模式三分支（null → init-device / os → upgrade-device / password 已解锁 → upgrade-device 带会话口令）+ 副标题 V2Desc；l10n 中英繁新增 V1Desc 新文案/V2Desc/解锁门 6 键。验证：test.sh 16 项全绿（新增 16：v1→v3 免密迁移 K 不变数据一致 + 补设恢复口令 + 换机 NEED_RECOVERY + v2→v3 正确口令成功/错误口令拒绝 + 已 multiseal 拒绝）+ flutter test 41 项全绿（新增：v1→v3/v2→v3 升级、v2 口令模式 needsPassword/unlock/持久化/错误口令复位、StreamingStore v2 预取与解锁）。
5. **第五步（加固与回归）**：跨平台指纹真机验证、熵文件篡改检测、锁定退避联动、全量回归 + 更新 credential-vault-plan 文档状态。
6. **第六步（v1↔v2 三档切换条 + 冷切）✅（2026-08-13）**：`VaultService.SwitchMode`（v1 ↔ v2 份额迁移——`newKeyVault = K ⊕ S'`，**K 不变条目沿用**；os 分支先落 OS 存储后写 vault 失败回滚删份额、password 分支写文件成功后删 OS 份额）+ `ServeSession` `switch-mode <os\|password> [<b64新口令>]` 分发；Dart `VaultProcess.switchMode` + `VaultSessionStore.switchMode`（成功后更新 `_mode`/`_vaultOk`/`_sessionPassword`——v1→v2 新口令即会话口令本会话保持解锁、v2→v1 清空口令免密；v3 多封装拒绝）+ `StreamingStore.syncPasswordState`（切换后同会话持久化按新模式带口令）；设置页「高级 · 凭据加密」**三档切换条**（`_ModeSegmented` 自绘等宽 pill：busy 全禁、v2 未解锁灰显 v1/v3、v3 点击 v1 toast 解释不可直达）+ v1→v2 新口令二次确认弹窗（`_NewPasswordField`）+ v3 开启/关闭后 store 模式同步；**v3 关闭分流（对称性修复）**：`status` 新增 `has_recovery` 字段 + `VaultService.HasRecovery`；`ClearDeviceSeal` 无恢复口令封装（纯熵绑定）时不再抛错——以调用方新设口令免授权降级（对称于「免密开启」，避免无口令用户被卡死；有 kind=1 仍验证恢复口令），UI `_disableDeviceBind` 按 `VaultProcess.hasRecovery` 分流：有→验证恢复口令弹窗、无→新设 v2 口令弹窗（`_promptNewV2Password` 复用 `_NewPasswordField`）；**切换完整性**：四条模式变更路径（v1↔v2、v3 启/闭）执行前先 `flush()` 排空会话/流媒体持久化队列（防在途写携带旧口令/免密约定落到切换后新布局 vault 失败丢数据），成功后弹**冷切引导**（`_promptRestartAfterModeChange`：明确警告 v2 模式重启后需口令解锁、解锁前登录态与流媒体凭据暂不可用显示未登录、重启期间播放下载中断；「立即重启」`_restartApp` = `Process.start(Platform.resolvedExecutable, executableArguments, detached)` + `windowManager.destroy`，失败降级提示手动重启）；**未初始化按 v1 展示**：`VaultProcess.mode` 对 `{"initialized":false}` 返回 `os`（默认 v1，惰性初始化后即此模式）——未登录/全新目录不再显示「加密等级读取中…」；**l10n 完整性**：新增 24+2 键（切换条标签/档位说明/弹窗/拒绝文案/toast/冷切重启 4 键/关闭 v3 新口令弹窗 2 键）全量同步中英繁；**de/es/fr/ja/ko 补齐完整键集**（一次性脚本将模板缺失键以模板值补入，消除部分翻译与 untranslated 警告——gen-l10n 0 untranslated，键集与模板一致 917 键；这些语言未翻译部分仍显示中文模板值，真正本地化属独立任务）。验证：test.sh 18 项全绿（新增 17：v1 init + set → 免密会话 `switch-mode password` + get 验证 → 无口令被拒 → 新口令解锁验证 → `switch-mode os` 免密回归 → status mode=os；15b 改新语义：纯熵绑定 `clear-device-seal` 新口令免授权降级 → 免密被拒 → 新口令回读数据一致）+ flutter test 44 项全绿（新增 v1↔v2 互切 + 未初始化 mode=os + v3 无恢复口令免授权降级回读）。

## 10. 验证计划

1. ✅ 本机免密：init-device 后 serve 会话（无口令）成功 set/get（test.sh 13-①）；
2. ✅ 换机落恢复：伪造不同指纹（`ARCHOERA_VAULT_FINGERPRINT`）→ 解封失败 → `err NEED_RECOVERY` → 恢复口令解锁成功且数据一致（test.sh 13-②③）；
3. ✅ 熵文件篡改：改 device.seal 1 字节 → GCM 认证失败 → NEED_RECOVERY（test.sh 13-④）；
4. ✅ 错误恢复口令 → 解锁失败触发锁定退避（test.sh 13-⑤）；
5. ✅ 回归：test.sh 15 项全绿 + flutter test（vault 相关 7 项）+ selftest（Argon2id 向量 + 熵密封往返）；
6. ✅ 恢复口令管理：修改后旧口令立即失效、新口令可恢复；rebind 后新指纹免密、旧指纹落 NEED_RECOVERY；清除口令后换机 fail-closed（test.sh 14-①~⑦）；
7. ✅ 关闭设备绑定：正确口令关闭回落 password 且数据一致、无口令被拒、错误口令被拒（test.sh 15/15b + flutter v3 Dart 测试）；
8. ✅ 迁移：v1/v2 → v3 升级后数据回读一致——v1 免密升级 K 不变条目沿用、v2 正确口令升级成功/错误口令拒绝、已 multiseal 拒绝重复升级（test.sh 16 + flutter test 41 项全绿）；
9. ✅ v1 ↔ v2 互切：K 不变数据沿用（免密 `switch-mode password` 后 get 验证）、无口令被拒、新口令解锁验证、`switch-mode os` 免密回归、v2 未解锁切回 os 被拒、v3 多封装经 switchMode 被拒（test.sh 17 + flutter test 42 项全绿）；

## 11. 风险与权衡

| 风险 | 应对 |
|---|---|
| 软件指纹可公开读取（§2 认知）| 定位为「迁移可用性 + 免密体验」，高价值场景叠加平台防线；文档如实声明 |
| 指纹漂移（重装/machine-id 变化）| 降级路径：落口令恢复 + 「重新绑定当前设备」；备选指纹源逐级 fallback |
| 熵文件与 vault 文件同盘被拷走（含指纹）| 同机攻击者按源码可解——开源约束下的既有认知（§2）；设备熵不防同机逆向 |
| 换设备且遗忘口令 | 销毁重建（重新登录），代价可接受（与 v2 一致） |
| v3 升级写坏 vault | 原子替换 + 写前完整校验，失败保留原文件；迁移可重试 |
| 多封装增加文件复杂度 | 封装块独立读写、selftest 向量覆盖；kind 字段预留扩展 |

---
