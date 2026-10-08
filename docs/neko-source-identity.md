# NekoMusic 音源请求方案（分层客户端身份）

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

我们既不是官方客户端，也不冒名 Android，也不做浏览器伪装（反爬对抗），
因此采用**分层身份**。

## 方案

### 主路径（优雅）：ArchoeraMusic 本体自报

所有 Neko 出站请求带：

```
User-Agent: ArchoeraMusic/<版本> (<平台>)
X-Neko-Client: archoera+<版本>
```

以 ArchoeraMusic 本体身份自报：服务端一旦落地「自报标识 `X-Neko-Client` 作为
正向证据」的放行逻辑，或把 `ArchoeraMusic` 纳入放行名单，即自动生效，
无需针对任何品牌做内置白名单。

### 回退（暴力）：纯 NekoMusic 桌面 UA 形状

当前线上服务端尚不认本体 UA（`ArchoeraMusic/…` 会被降级）。客户端在
`NekoClient` 中检测「响应被降级」（见 `nekoIsDegradedResponse`：HTTP 200 +
`text/html` / SEO HTML，或非 GET 的 `403` + 统一拒绝文案）后，**进程内一次性**
切换到：

```
User-Agent: NekoMusic-<平台>/<版本>
X-Neko-Client: archoera+<版本>   # 始终保留本应用标识
```

回退只更换 UA **形状**以命中服务端 `isNativeClient` 锚定正则，语义不变：
不冒名 Android、不补浏览器特征头、不参与反爬对抗。
服务端支持自报标识后，应移除该回退（保留主路径即可）。

### 站点图片（封面 / 头像）

图片经全局 `HttpClient`（浏览器 UA）发起，`Image.network` 以 `add` 语义追加
请求头、无法覆盖 UA，故图片侧无法换用分层 UA，只补标识头与浏览器特征头：

```
X-Neko-Client: archoera+<版本>
Accept: image/*
Accept-Language: zh-CN,zh;q=0.9,en;q=0.8
```

新服务端靠 `X-Neko-Client` 放行；现存服务端靠浏览器完整性放行。封面 / 头像本身
在防重放豁免清单内。

### 防重放

`NekoClient` 的 nonce 池按站点批量预取读 / 写两类 nonce，用后即弃，本地 90s
提前作废；收到 `409`（`X-Neko-Replay-Status: missing|invalid`）时清池、换新 nonce
重试一次。切换回退身份时会连同旧标识下领到的 nonce 一并作废。

## 不变量

- `User-Agent` 始终非空（主路径为 `ArchoeraMusic` 本体、回退为纯 NekoMusic 桌面形状）。
- `X-Neko-Client` 始终为 `archoera+<版本>`，表达真实来源。
- 不带 Android 平台标识，不做浏览器 UA / 特征头伪装。
- 被降级且回退仍无效时，`NekoClient` 明确抛错，绝不把 SEO HTML 当作业务成功。
