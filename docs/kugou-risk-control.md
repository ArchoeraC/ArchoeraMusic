# 酷狗 API 新版方案与账号风控分析

> 分析对象：MoeKoeMusic `1.7.2`（`4dac953`，2026-11-08）与其依赖的
> MakcRe/KuGouMusicApi `1.6.3`（`7ac64e1`，2026-11-04；MoeKoeMusic 锁定
> `5d6c9f7`）。参考克隆位于工作区 `SPlayer-Next/MoeKoeMusic` 与
> `SPlayer-Next/KuGouMusicApi`，不参与本项目构建。
>
> 结论先行：新版方案的核心不是新的加密算法，而是**稳定设备身份 + 设备
> 注册协议升级 + lite 登录设备信封**。旧实现每次启动随机 MID、每次取流
> 随机 dfid、验证码登录使用静态 t1/t2，才是账号被风控的主要来源。

## 1. 上游新版做了什么

### 1.1 安装级设备身份（最关键）

MoeKoeMusic `electron/util/kugouapi/deviceUtil.js` 为每个安装生成并持久化：

| 字段 | 生成方式 | 用途 |
| --- | --- | --- |
| `uuid` | UUID v4 | `KUGOU_API_GUID`，注册设备时的 `imei`/`uuid` |
| `mid` | `calculateMid(uuid)`：`md5(uuid)` 的 hex 当大整数转十进制 | 所有请求的 `mid` 参数与请求头 |
| `dev` | 10 位大写随机串 | `KUGOU_API_DEV`，登录/扫码/上报的设备名 |
| `mac` | 固定 `02:00:00:00:00:00` | `KUGOU_API_MAC`，不暴露真实网卡 |
| `webgl` | 随机 uint64 十进制（服务端环境） | SSA 行为指纹的 `webgl` 字段 |

这些值必须**跨重启复用**。MoeKoeMusic 在 Electron store 中保存；我们此前
每次进程启动重新生成 `mid`，每次 `status=2` 重置 dfid，等于每次都在扮演
一台新设备，这是最容易被判定为设备农场的模式。

### 1.2 设备注册升级到 v3

KuGouMusicApi `module/register_dev.js` 在 `1c73c64`（2026-10-24）把
`/risk/v2/r_register_dev` 改为 `/risk/v3/r_register_dev`，提交说明是
「修复 /register/dev 获取失败问题」。协议本身未变：

1. 设备信息 JSON 用 AES-128-CBC 加密（随机 6 位 key，key/iv 由 MD5 派生）；
2. `p = RSA-PKCS1({aes, uid, token})`；
3. 响应也是 AES 密文，需用同一 key 解密后才能取 `data.dfid`。

v2 返回空 dfid 时客户端往往会重新注册/换设备，进一步放大风控。

### 1.3 lite 登录设备信封

`module/login_cellphone.js`（概念版 `platform=lite`）不再使用静态 `t1=0,
t2=0, t3=...`，而是现场生成：

```text
t1 = AES-256-CBC("|<clienttime_ms>", liteT1Key, liteT1Iv)
t2 = AES-256-CBC("<guid>|0f607264fc6318a92b9e13c65db7cd3c|<mac>|<dev>|<clienttime_ms>",
                 liteT2Key, liteT2Iv)
```

请求体同时需要 `dfid`、`dev`、`gitversion=5f0b7c4`；账号密码登录
（`module/login.js`）也增加了 `dev`；扫码轮询
（`module/login_qr_check.js`）增加 `dev`；`login_qr_key.js` 的
`qrcode_txt` 使用当前平台 appid（lite 为 3116），不是 `srcappid=2919`。

### 1.4 SSA 二次验证与 sid/edt

`util/request.js` 检测响应头 `ssa-code` / `SSA-CODE`，命中时用
`util/generate_simulate.js` 生成模拟行为指纹：

- `edt = AES-128-CBC("mid=...;userid=...;dfid=...;webgl=...;webdriver=0;ts=...;data=...")`
  （固定 IV `kugousecurity123`，data 为贝塞尔鼠标轨迹/滚动/窗口事件）；
- `sid = RSA-OAEP-SHA256(AES key)`（公钥从酷狗 WASM 提取）。

上游只是把 `edt`/`sid`/`ssaCode` 附加到响应，真正提交验证由
`module/verify_user_info.js`（`/v4/verify_user_info`）或 `module/sidedt.js`
完成，并未在普通请求里自动重试。我们**没有**默认伪造行为指纹——它只对
「已触发验证」的账号有意义，且需要与真实设备/行为一致；先保证不主动
制造风控信号更重要。

### 1.5 云歌单加密协议

`util/request.js::createCloudRequest` 为
`cloudlist.service.kugou.com` 提供 RSA + AES-CBC 的请求/响应加密，目前
上游主要用于歌单排序（`playlist_sort.js`）等写操作。我们现有的
「我喜欢」增删、用户歌单读取仍走普通网关，上游对应模块也仍是普通请求，
因此本期不迁移。

## 2. 本项目已落地的改进

| 改动 | 文件 | 说明 |
| --- | --- | --- |
| 安装级设备身份 | `app/lib/services/kugou/kugou_device.dart` | `guid/mid/dev/mac/webgl/dfid` 生成、序列化、持久化复用 |
| 设备持久化接线 | `app/lib/services/kugou/kugou_api.dart` | 设备存于 sessionStore 的 `kugou_device` 键，与登录会话分离；退出登录不清设备 |
| dfid 持久化 + 并发去重 | `app/lib/services/kugou/kugou_api.dart` | 复用磁盘 dfid；并发注册合并为一个 Future；失败后 90s 退避（避免取流降级时密集注册）；`status=2` 只重注册**同一设备** |
| 注册接口 v3 | `app/lib/services/kugou/kugou_request.dart` | `/risk/v3/r_register_dev`；注册使用持久化 GUID/MID |
| lite 验证码登录信封 | `app/lib/services/kugou/kugou_request.dart` | 现场生成 t1/t2，body 带 `dfid/dev/gitversion` |
| 登录/扫码设备名 | `app/lib/services/kugou/kugou_request.dart` | 密码登录带 `dev`；扫码轮询带 `dev`；二维码 `qrcode_txt` appid 对齐 lite |
| AES 原始 key/iv | `app/lib/services/kugou/kugou_crypto.dart` | `kgAesEncryptHexRawKeyIv`，对齐 `cryptoAesEncrypt(data, {key, iv})` |
| 回归测试 | `app/test/kugou_device_test.dart` | 设备跨实例稳定、v3 端点、t1/t2 与 Node/OpenSSL 向量一致 |

## 3. 仍需注意 / 后续可做

1. **SSA 自动处理**：目前请求层不解析 `ssa-code`。如果真实账号开始频繁
   收到验证，应先降低请求频率、检查出口 IP 是否与登录地一致，再考虑
   接入 `/v4/verify_user_info`；不要无条件伪造 `sid/edt`。
2. **云歌单加密写操作**：歌单排序等新接口可能需要 `createCloudRequest`；
   当前只读/增删路径未被上游切换，暂无迁移必要。
3. **设备重置入口**：若用户确实需要「换设备」，应做成显式的设置项，
   并在重置后同步清理 dfid，而不是在异常分支里偷偷换。
4. **请求频率**：批量拉歌单/榜单已有页数与安全上限；新增批量接口时要
   保持串行/小并发，避免短时间大量请求被账号级限流。
5. **代理/IP 一致性**：如果用户配置代理，登录、注册、取流应尽量走同一
   出口；频繁跨地区切换本身也是风控信号。
