# NekoMusic 音源请求方案（客户端身份与放行）

本文记录 ArchoeraMusic 与 NekoMusic 服务端通信时的**身份与放行**方案，对应实现：
`app/lib/services/neko/neko_identity.dart`、`app/lib/apis/neko/neko_client.dart`、
`app/core/audio-engine/src/decoder.c`。

## 背景

NekoMusic 服务端有两条与「谁在请求」相关的约束：

1. **防爬 / 客户端区分**（`CrawlerProtectionFilter`）
   - 空 / 缺失 `User-Agent` 一律按爬虫处理（`GET` 直出 SEO HTML，其它方法 `403`）；
     旧版「空 UA 直接放行」的旁路已拆除。
   - 官方原生客户端 UA 为**整体锚定**的 `NekoMusic-<平台>/<版本>`
     （平台限 `android|pc|ios|macos|windows|linux|qt`，版本以数字开头）。
   - 未知 UA 会被降级为 SEO HTML；第三方客户端可通过服务端
     `network.allow_client_user_agents` 登记，或（在支持后）以自报标识放行。
2. **请求防重放**（`ReplayProtectionFilter`）：全部动态接口需一次性
   `X-Neko-Nonce`，缺失 / 重放返回 `409`。

我们既不是官方客户端，也不冒名 Android，也不做浏览器伪装（反爬对抗）。

## 方案：官方锚定桌面 UA 形状 + `X-Neko-Client` 自报

所有 Neko 出站请求（REST / SSE / 音频下载 / 引擎 AVIO / 原生 HTTP）带：

```
User-Agent: NekoMusic-<平台>/<版本>     # 官方锚定的桌面形状（windows|macos|linux）
X-Neko-Client: archoera+<版本>          # 始终表达真实来源
```

早期版本曾保留一条「主路径」：以 `ArchoeraMusic/<版本> (<平台>)` 本体自报。**实测服务端
不认该自报 UA**——换题等动态接口会返回 SEO HTML，导致拿不到 nonce、所有受保护请求持续
`409`。因此该主路径已**移除**：只保留官方锚定的桌面 UA **形状**（版本以数字开头；读取失败
回退 `0`），来源声明统一由 `X-Neko-Client` 承担。

复用官方 UA 形状只为通过 `isNativeClient` 锚定正则，**语义不变**：不冒名官方品牌、不带
Android 平台标识、不补浏览器特征头、不参与反爬对抗。服务端一旦落地「自报标识
`X-Neko-Client` 作为正向证据」的放行逻辑，该头即自动生效，无需针对任何品牌做内置白名单。

### 站点图片（封面 / 头像）

图片经全局 `HttpClient`（浏览器 UA）发起，`Image.network` 以 `add` 语义追加
请求头、无法覆盖 UA，故图片侧无法改用桌面 UA，只补标识头与浏览器特征头：

```
X-Neko-Client: archoera+<版本>
Accept: image/*
Accept-Language: zh-CN,zh;q=0.9,en;q=0.8
```

新服务端靠 `X-Neko-Client` 放行；现存服务端靠浏览器完整性放行。封面 / 头像本身
在防重放豁免清单内。

### 防重放（领取必须先换题）

服务端自「领取 nonce 必须携带挑战」起，`GET /api/replay/nonce` 不再接受裸领取。
`NekoClient` 的 nonce 池按站点走**两步领取**（对齐官方 PC 端 `ReplayNonceStore`）：

1. `GET /api/replay/challenge?read=16&write=16` 换题，读 `challenge` / `seed` /
   `difficulty` / `algorithm`；
2. 比对 `algorithm == "sha256-leading-zero-bits"`（不认识就不盲解，放弃本轮），
   在**后台 isolate**（`nekoSolveProof`，见 `apis/neko/neko_replay.dart`）找一个
   十进制计数器，使 `SHA-256(seed + ":" + counter)` 的前导零比特数 ≥ `difficulty`，
   取其十进制串作 `proof`；
3. `GET /api/replay/nonce?challenge=&proof=` 兑换读 / 写两类 nonce。

兑换被拒（`400` / `409`，服务端不区分原因）时换新题重解一次；限额 `429` / 服务不可用
`503` 时本轮打住（不紧循环撞限额），交给下次补领。批量预取、用后即弃，本地 90s 提前
作废；消费 `409`（`X-Neko-Replay-Status: missing|invalid`）时清池、换新 nonce 重试一次。

为兼容尚未提供挑战接口的旧服务端，换题返回 `404` 时回退为不带挑战的 `read` / `write`
直接领取。挑战解题是 `2^difficulty` 量级的哈希计算，放在后台 isolate，不阻塞 UI；
`nekoSolveProofSync` / `nekoMeetsDifficulty` 为纯函数，便于单测。

换题 / 兑换本身也是动态接口，同样经防爬过滤器，与业务请求共用同一套身份头。

## 不变量

- `User-Agent` 始终非空，且为官方锚定桌面形状 `NekoMusic-<平台>/<版本>`。
- `X-Neko-Client` 始终为 `archoera+<版本>`，表达真实来源。
- 不带 Android 平台标识，不做浏览器 UA / 特征头伪装。
- 服务端若仍把该请求降级为 SEO HTML，`NekoClient` 明确抛错，绝不把 SEO HTML 当作业务成功。
