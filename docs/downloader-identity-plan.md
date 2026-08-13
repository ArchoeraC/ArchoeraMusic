# 下载器身份隔离规划

> 状态：**实施中（2026-08-13：动态指纹开关完成）** · 规划稿 2026-08-12
> 定位：消除下载器「全用户共享同一设备指纹/伪装特征」的封号隐患——实现**用户级持久化随机指纹**，
> 隔离平台风控聚类，同时把「签名盐」从伪风险中正确定位（公开逆向产物，不视为秘密）。
>
> 实施进度：
> - **第一步（指纹持久化注入）✅（2026-08-12）**：Rust `DownloaderIdentity` + `archoera_downloader_set_identity` FFI（kgMid 显式优先 / kgGuid 推导 / 未注入回落随机）；resolvers.rs `build_netease_cookie` 的 deviceId/_ntes_nuid 注入值优先（用户 cookie > 注入指纹 > 随机）；Dart `generateDownloaderIdentity()`（kgGuid+kgMid+nmDeviceId+nmNuid，复用 kgRandomString/kgCalcMid）+ prefs `downloaderIdentity` 持久化 + 引擎 init 注入；设置页「重置设备指纹」入口（9 语言 l10n，重置后经 `syncSessions` 即时重注入）。回归：cargo test 26+11 全绿、dart analyze 干净。
> - **第二步（伪装本地化 + 行为节流）✅（2026-08-12）**：Rust `lib.rs` 新增节流模块——`failure_backoff()`（连续失败指数退避 300ms→…→4.8s 封顶 + ±50% 抖动）+ `request_pacing()`（每分钟 60 请求上限频率门，窗口满等待最旧滑出）+ `reset_failures()`；四类请求（nm_download_url / nm_player_url / kg_register_device / kg_song_url）发起前 pacing、失败 backoff、成功 reset 全部接入；`DownloaderIdentity` 新增 `osver` 字段（serde camelCase，json 键 `osver`），`build_netease_cookie` 注入值优先回落硬编码；Dart `generateDownloaderIdentity()` 新增 `osver`（`generateOsver()`：Windows 读真实系统版本映射 `Microsoft-Windows-{10|11}-Professional-build-{build}-64bit`，build≥22000 记 Win11；Linux/macOS 回落官方 Windows 值——网易 osver 仅接受 Windows 风格字符串，改真实系统名会被服务端拒绝，见 §5 权衡）。回归：cargo test 26+11 全绿、dart analyze 干净、flutter test 35 项全绿（ARCHOERA_VAULT_INSECURE_FILE_STORE=1）。
> - **第三步（动态指纹开关）✅（2026-08-13）**：为「部分用户可能需要旧版动态值行为」增设开关，默认关闭，放设置「下载 · 设备指纹」区块——prefs `download.dynamicFingerprint`（默认 false）；Dart `_injectIdentity()` 按开关注入/清除，开关切换经 `syncSessions()` 即时生效（不必等重启）；Rust 新增 `archoera_downloader_clear_identity`（清空 identity + 置空 mid）+ `kugou_mid()` 惰性生成（None 时生成会话随机并写回，本会话内稳定，模拟旧版 init 随机一次）；「重置设备指纹」在开关开启时禁用（指纹不持久化，重置无意义）。9 语言 l10n 2 键。回归：cargo test 27+11 全绿、dart analyze 干净、flutter test 46 项全绿。
> - 第四步（盐混淆，可选）：未开始

---

## 1. 背景与现状盘点

下载器（`app/core/downloader`，Rust）请求酷狗/网易接口时，存在两类「硬编码」，**风险性质完全不同**：

### 1.1 签名盐/公钥（`crypto.rs`）——公开逆向产物，伪风险

```
KG_SIGN_SALT / KG_LITE_SIGN_SALT / KG_KEY_SALT / KG_LITE_KEY_SALT
KG_LITE_APPID = 3116
KG_PUBLIC_KEY_PEM / KG_LITE_PUBLIC_KEY_PEM（RSA 公钥）
网易 weapi AES key（0CoJUm6Qyw8W8jud 等）
```

- 这些盐值**不是本项目独有的秘密**：官方客户端内置、KuGouMusicApi/MoeKoeMusic 等第三方实现公开可见；
- 硬编码它们不增加被破解风险（攻击者无需逆向本项目），且**无法移除**（签名算法硬性依赖，`kg_sign_key`/`kg_signature`/`kg_sign_params_key` 的 md5 拼接强制使用）；
- 结论：**藏盐只做表面混淆，不解决封号问题**，定位为可选优化（§4.4）。

### 1.2 设备指纹与伪装特征（`resolvers.rs` / `lib.rs`）——真正的封号风险点

| 项 | 现状 | 风险 |
|---|---|---|
| 酷狗 `mid` | 进程级随机（`kg_calc_mid(kg_random_string(16))`），**不持久化** | 同一用户每次启动换指纹，符合真机行为的应是固定设备 |
| 酷狗 `dfid` | register_dev 注册所得，进程内存缓存 | 同 mid |
| 网易 `deviceId`/`_ntes_nuid`/`WNMCID`/`NMTID` | 每次请求随机 | 同 mid |
| **`osver`（Windows 10 19045）/`appver`（3.1.17）/channel** | **硬编码，全用户相同** | **群体指纹**：风控按「同一 osver+appver+device 组合 + 高频下载」聚类封禁，全体用户连带遭殃 |
| 用户 `MUSIC_U`/`token`/`userid` | Dart 注入、不进二进制 | 已隔离（保持） |

风控的核心聚类维度正是**群体共享的伪装特征**，这是「寻迹封号、损失不可逆」的真正来源。

---

## 2. 目标

1. **设备指纹用户级持久化随机**：不同用户 → 不同指纹；同一用户 → 指纹稳定（首次生成后不变）；
2. **伪装特征本地化**：`osver`/`appver` 从真实系统信息生成或用户级随机扰动，消除群体指纹；
3. **请求行为节流**：并发上限、频率限制、连续失败指数退避 + 随机抖动；
4. **签名盐定位正确**：不视为秘密，可选做编译期混淆（仅防脚本小子）；
5. 不影响签名正确性（`clientver` 参与签名，保持官方值）。

---

## 3. 方案

### 3.1 设备指纹持久化（核心）

采用 **Dart 主进程生成并持久化，FFI 注入**（复用 `setKugouSession` 注入模式，Dart 已有 prefs 基础设施）：

- Dart 侧首次启动生成 `downloaderIdentity` JSON（含 `kgGuid`、`kgMid`、`nmDeviceId`、`nmNuid` 等），存入 prefs，此后不变；
- 下载器 init 时经 FFI 注入；Rust 侧 `kugou_mid()` / 网易 cookie 生成**优先使用注入值**，无注入才回落进程随机；
- 用户「清除数据」时一并重置指纹（可选）。

**为什么不用 Rust 侧自持久化**：Dart 是主进程，prefs 已有统一管理（含设置页清除），跨会话一致；Rust 是短命 CLI 子进程，自持久化需自行管理配置目录，与现有架构不一致。

### 3.2 伪装特征本地化

| 项 | 是否参与签名 | 方案 |
|---|---|---|
| `osver`（网易 cookie） | 否 | 读真实系统版本（`os_info` crate 或按 `target_os` 映射），不再硬编码 Windows 10 19045 |
| `appver`（网易 cookie/UA） | 否 | 保持官方值（服务器可能校验）或用户级小幅扰动，评估后定 |
| `clientver`（酷狗 11440/11430） | **是**（`kg_sign_params_key` 参与拼接） | **保持官方值**，不可动 |
| `device`（酷狗 marble） | 注册设备参数 | 保持官方值（服务器可能校验） |
| `dfid`/`uuid`/`guid` | 否 | 随机化（guid 已随机，dfid 注册所得） |

### 3.3 请求行为节流

- Dart 下载队列：并发上限（现状如有则校准）、每分钟下载数上限（用户可调）；
- Rust resolvers：连续失败**指数退避 + 随机抖动**（人类化节奏），`needs_dfid_refresh` 重试仍保留；
- 目的：降低触发风控的频率聚类，不牺牲正常下载体验。

### 3.4 签名盐混淆（可选，P2）

- `crypto.rs` 盐常量拆段 + XOR 编码，运行时解码拼装，提高静态分析门槛；
- 明确认知：防脚本小子，不防有心逆向，不解决封号问题；
- 若不划算可不做（盐本就是公开产物）。

### 3.5 凭据安全（保持现状）

- `MUSIC_U`/酷狗 `token` 仅 Dart 侧持有、FFI 内存注入、日志脱敏（长度掩码）；
- 登录态清除时一并销毁，不进任何持久化日志。

---

## 4. 改动点清单

| 层 | 文件 | 改动 |
|---|---|---|
| Rust 身份 | `app/core/downloader/src/lib.rs` | 新增身份注入（`set_downloader_identity` 或扩展 init 参数）；`kugou_mid()` 优先用注入值；网易 cookie 生成的 deviceId/nuid 优先用注入值 |
| Rust 伪装 | `app/core/downloader/src/resolvers.rs` | `osver` 本地化（真系统版本）；失败退避 + 抖动 |
| Rust 盐混淆（P2） | `app/core/downloader/src/crypto.rs` | 常量拆段 XOR（可选） |
| Dart 指纹 | `app/lib/stores/prefs_*` | 新增 `downloaderIdentity` 键；首次生成持久化 |
| Dart 注入 | `app/lib/services/downloader/downloader_ffi.dart` | init 时注入 identity JSON（对齐 setKugouSession 模式） |
| Dart 节流 | 下载管理/队列 | 并发与频率上限 |
| 测试 | `tests/crypto_roundtrip.rs` 等 | 身份注入回退、osver 本地化回归 |

## 5. 风险与权衡

| 风险 | 应对 |
|---|---|
| 指纹持久化后若被风控盯上，该用户指纹固定（不再能靠换指纹自愈） | 设置页提供「重置设备指纹」入口；dfid 刷新机制保留（v5/url status=2 时重新注册） |
| `osver` 本地化可能改变服务端行为 | 先在 Linux 验证下载全流程，再推广三平台；评估不通过则退回官方值 |
| `appver`/`clientver` 改动导致签名或校验失败 | `clientver` 明确不动（参与签名）；`appver` 默认保持官方值，仅评估 |
| 跨 Dart/Rust 两层 | 分三步落地（§6），每步可独立回归 |

## 6. 分步落地

1. **第一步：指纹持久化注入**——Dart prefs 生成/存储 identity + FFI 注入 + Rust 优先用注入值（回落随机保留）；验证「不同 prefs 不同指纹、同 prefs 重启不变」；
2. **第二步：伪装本地化 + 行为节流**——`osver` 本地化、失败退避抖动、Dart 并发/频率上限；
3. **第三步（可选）：盐混淆 + 回归**——crypto 常量混淆（评估成本收益），全量测试回归。

## 7. 验证计划

1. 同用户：连续两次启动下载，酷狗 mid / 网易 deviceId 不变（指纹稳定）；
2. 异用户：两套 prefs 下指纹不同（隔离生效）；
3. 下载全流程回归：酷狗（v5/url、register_dev、付费墙降级）、网易（weapi song/url、登录态下载）；
4. 连续失败场景：退避 + 抖动生效，无雪崩重试；
5. `flutter analyze` + `cargo test` 全绿。
