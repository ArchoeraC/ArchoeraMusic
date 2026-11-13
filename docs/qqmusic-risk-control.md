# QM API 风控优化分析

> 分析时间：2026-11-11。对照若干公开的第三方 QM 客户端 / 插件与 API 实现
> （只读，不参与本项目构建；具体项目名称与提交不在本文展开）。
>
> 结论先行：**新版方案的共同点不是新算法，而是「稳定设备身份 + 真实
> QIMEI + 请求节奏控制」**。我们此前把 `udid/OpenUDID/QIMEI36` 写成 `'0'`，
> 每次取流又随机换 GUID，再叠加两层各自 2 次的重试——这三件事正是账号被
> 账号级限流（`inner=2001`）的主要来源。

## 1. 实测：风控到底怎么触发的

2026-11-11 在本机出口直接对 `u.y.qq.com` 做只读探测（不含任何账号操作）：

| 实验 | 结果 |
| --- | --- |
| 同一出口连续发 4 次 `DoSearchForQQMusicDesktop`（0s 间隔） | 前 2 次正常，第 3~4 次 `inner=2001`，`sum=0` |
| 静置 ~90s 后同一 payload | 恢复正常（`sum=1000`） |
| `musics.fcg` 不带 `?sign=` | 外层 `code=2000`，业务失败（**签名必需**） |
| `musicu.fcg` + `ct=19` 桌面 comm（不带 sign） | `inner=2001`（桌面协议只能走 `musics.fcg`） |
| `music.getSession.session`（Android comm） | 正常返回 `uid/sid/userip` |
| `AlbumSongList` + `session:true`（带 uid/sid） | 正常 |
| `AlbumSongList` + 仅 Android comm（无 session） | `code=500001` |
| `song_url` 访客 + 静态 cookie | `req_0.code=1000`，`retcode=104009`，`msg="<ip>;invalidq;"` |

**要点**：

1. 限流按**速率**判定，与参数无关——不是「某个接口不能用」，而是「打太快」。
2. `inner=2001` 与 `code 0 + meta.is_filter<0` 是同一族信号（风控/额外验证），
   都必须当作失败，且**不能重试**。
3. 桌面协议（`musics.fcg`）必须签名；移动协议（`musicu.fcg`）不需要签名但
   **必须带 `music.getSession` 的 uid/sid**，并且设备指纹要像真机。
4. `song_url` 的 `retcode=104009 invalidq` 是「签名/设备参数无效」，不是
   「没 VIP」——我们此前会把它当成普通 403，然后按音质档位再打 8 次。

## 2. 上游新版做了什么（可借鉴的部分）

### 2.1 设备档案 + QIMEI（最关键）

公开实现中的 Python 设备/设备档案模块与 Node 侧 QIMEI 模块是同一套协议：

1. 生成一台**自洽**的 Android 设备：机型 / 主板 / 厂商 / 系统版本 / API level
   / IMEI（满足 Luhn）/ androidId / MAC / OpenUDID / boot_id 互相匹配；
2. 把这些字段用 `POST https://api.tencentmusic.com/tme/trpc/proxy` 上报，
   `appid=qimei_qq_android`，取出服务端签发的 `q16/q36`；
3. 业务请求的 `comm` 带 `QIMEI36 / OpenUDID / udid / aid / phonetype / os_ver`；
4. QIMEI 缓存 24h，随设备文件落盘复用。

`L-1124` 的 `VersionPolicy` 还做了**平台隔离**：Android 用
`ct=11, cv=20090008`（20.9.0.8），桌面用 `ct=19, cv=2201`，网页用
`ct=24, cv=4747474, platform=yqq.json`——不会出现「UA 说一个版本、comm 说
另一个版本」的拼凑组合。

### 2.2 稳定的 GUID

部分插件仍用社区共享的硬编码 GUID
（`1F70E520B2EAA7D25E11760783C53CA9`）；某聚合库
**每次取流随机生成 GUID**（`fmt.Sprintf("%d", r.Int63n(9000000000)+1000000000)`），
注释还写着 "Use a random GUID to reduce the chance of rate limiting"。

实测与结论：**随机 GUID 反而更容易被限流**。同一账号在一小时内出现在
几百个「新设备」上，本身就是设备农场特征。正确做法是「一次生成、长期
复用」，只有用户显式重置设备才换。

### 2.3 请求节奏与重试

`L-1124` 在 0.8.0 引入「统一请求内核 + 请求合并 + 上游失败标记熔断」，并把
`RateLimitError` 重命名为 `GlobalAuthFailedError`——即**风控是全账号状态**，
不是单接口状态，遇到就该全局停手。我们此前在请求层与模块层各写了一套
重试，彼此不知道对方存在，合起来一次搜索最多 9 个请求。

### 2.4 音质档位收敛

某插件的档位表只保留 5 档（m4a/128/320/ape/flac），高解析
另走 `size_new`；该聚合库一次请求也只带「按账号是否 VIP 挑出来的
≤7 个」文件名。我们此前对一次取流固定发 9 个档位（含 RS01/AI00/Q001/Q000），
既是批量刷取特征，也让「无效档位」把请求体积放大 3 倍。

## 3. 本项目已落地的改进

| 改动 | 文件 | 说明 |
| --- | --- | --- |
| 安装级设备身份 | `app/lib/apis/qqmusic/core/device.dart` | `guid/udid/OpenUDID/androidId/imei` + 自洽设备档案；持久化到 sessionStore 的 `qqmusic_device`，与登录会话分离（退出登录不丢设备） |
| QIMEI 注册 | `app/lib/apis/qqmusic/core/qimei.dart` | RSA(PKCS#1)+AES-128-CBC 上报换 `q16/q36`，缓存 24h 落盘；失败静默不影响业务 |
| comm 真实化 | `app/lib/apis/qqmusic/core/config.dart` | `udid/OpenUDID/aid/QIMEI36/phonetype/os_ver/cv/UA` 全部来自设备身份；不再写死 `'0'` |
| 节奏闸门 | `app/lib/apis/qqmusic/core/pacing.dart` | 限并发 3 + 最小间隔 150ms + 风控冷却（60s 起，指数退避，上限 10min）；冷却期**直接失败不联网** |
| 统一入口接线 | `core/request.dart` | `qmPostRaw` 统一过闸门（含自建请求体的 `search.dart` / `song_url.dart`）；`qmRequest` 冷启动即检查冷却 |
| 重试收敛 | `core/request.dart`、`modules/search.dart` | 传输级错误只重试 1 次；业务码/风控**一律不重试** |
| 取流稳定化 | `modules/song_url.dart` | GUID 用设备身份（不再随机）；UA 与 comm 同源；候选档位从 9 收敛到 3；`retcode=104009`/2001 记风控冷却 |
| 搜索 GUID | `modules/search.dart` | 桌面 comm 的 `guid` 改为设备身份（不再用社区共享常量） |
| 凭据库接线 | `stores/vault_session_store.dart`、`stores/vault_unlock_refresh.dart` | `qqmusic_device` 纳入 knownPlatforms；解锁后显式失效设备缓存（与 cookies 同源污染） |
| 回归测试 | `app/test/qqmusic_risk_control_test.dart` | 18 条：设备稳定性/QIMEI 形状/闸门/冷却/重试策略 |

## 4. 仍然存在、但**不建议**做的

1. **不要伪造 `q36`**。QIMEI 必须由服务端签发；本地随便编一个 36 位串比不带
   更糟（会被判为伪造设备）。注册失败时我们发空串，不发假值。
2. **不要自动解验证码 / 打码平台**。`meta.is_filter=-2`（需额外验证）出现时
   应提示用户「稍后再试 / 换网络」，而不是模拟验证流程。
3. **不要在多账号间共享设备身份**。一个安装一套设备；如果用户切换账号，
   设备保持不变是正常的（手机换号不换机），但不要为了「防关联」在账号间
   轮换设备——那才是关联特征的反面。
4. **不要为每个请求换 IP**。出口 IP 与登录地不一致本身就是风控信号；
   代理配置应保证登录、取流、搜索走同一出口。

## 5. 后续可做（按收益排序）

1. **`song_url` 结果缓存**：同一 `(mid, level)` 在 URL 有效期内复用，
   播放器的 seek/重播不应重复取流（当前每次进播放页都可能取一次）。
2. **失败档位记忆**：某曲目在 `lossless` 档拿到 104009 后，短期记住并直接
   从 `hq` 开始，避免每次都从最高档试起。
3. **搜索 fallback 到移动协议**：`musics.fcg` 签名协议在风控期会整体失败，
   而 `musicu.fcg` + `searchBase`（某插件的搜索入口）用的是另一条
   通道，可作为只读搜索的降级路径（注意它不带 `ct=19`，无完整音质字段）。
4. **设备重置入口**：设置项里加「重置 QM 设备身份」，并在重置时同步清空
   QIMEI 缓存；正常用户不该用到，但排障时需要。
5. **风控可观测性**：把 `qmPacingSnapshot()`（在途数/连击数/冷却剩余）暴露到
   诊断页，便于用户反馈时判断是「网络问题」还是「被限流」。
