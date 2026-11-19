# NekoMusic 音源请求与登录方案

本文记录 ArchoeraMusic 与 NekoMusic 服务端通信时的**登录与请求**方案，对应实现：
`app/lib/apis/neko/neko_auth_client.dart`、`app/lib/services/neko/neko_api.dart`、
`app/lib/apis/neko/neko_client.dart`。

> **变更记录**
>
> - **2026-11-19**：恢复**应用内账号密码登录**。实现方式是复刻官方 PC 客户端的
>   SSO 兑换链路（NekoMusic 后端用自有机密客户端生成 state / PKCE，再由我们用
>   NekoAuth 的 JSON 接口完成授权），全程内置 HTTP：**不打开系统浏览器、不注册
>   `nekomusic://` 深链、不需要我方的 OAuth 客户端身份**。扫码登录保留。
> - **2026-11-09**：曾整体移除「浏览器 OAuth + `nekomusic://` 深链 + 传统账号
>   密码」。移除的是浏览器回调与旧的 `/api/user/login`；本次没有恢复它们，账号
>   密码只用于换取 NekoAuth 令牌，且不做本地保存。

## 登录

两种方式互斥，界面可切换：

| 方式 | 适用 | 代价 |
| --- | --- | --- |
| 账号密码（应用内） | 没有手机端登录态、或想长期免扫码 | 需要一次账号密码；之后靠 Auth 刷新令牌静默续期 |
| 扫码 | 手机端已是登录态 | 需要 NekoMusic 手机 App |

账号密码登录**默认关闭**，需在「设置 → 实验性音源 → NekoMusic → 应用内
账号密码登录」里显式打开；关闭时登录框只提供扫码。

### 账号密码登录（应用内，纯 HTTP）

五步，全部走内置 `HttpClient`：

1. `POST {music}/api/user/sso/start` `{"client":"pc","returnTo":"/"}`
   NekoMusic 后端用它自己的**机密客户端**生成一次性 `state` / `nonce` / PKCE，
   返回授权地址；我们只从这个地址的 origin 推出 NekoAuth 地址（不硬编码域名）。
2. `POST {auth}/api/auth/login` `{identifier, password, device}`
   账号密码换 Auth access token；`Set-Cookie` 里的 `refresh_token` 是整条授权链
   的根（14 天滚动），随会话一起加密保存。`device` 如实上报
   `{"type":"desktop","platform":"linux|windows|macos","source":"app"}`。
3. `GET {auth}/api/oauth/authorize?<步骤 1 的 query 原样>`
   NekoMusic 的 `redirect_uri` 是第一方 https，NekoAuth 会**自动同意**并直接在
   `redirectUrl` 里给出授权码；若部署未配置第一方父域（返回 `null`），退回
   `POST /api/oauth/authorize/decision` 显式同意。`state` / `nonce` /
   `code_challenge` 必须原样透传。
4. `GET redirectUrl`（**不跟随重定向**）
   授权码由 NekoMusic 后端用它自己的密钥交换；客户端只从 `Location` 取一次性
   `handoff`（120 秒有效）。
5. `POST {music}/api/user/sso/claim` `{handoff}`
   换回 NekoAuth access token（本客户端 `accessTokenTtlSeconds` 约 **364 天**）。

**不需要我方 OAuth 客户端**：`client_id` 归 NekoMusic 所有、只出现在步骤 1 返回的
授权地址里；机密客户端的密钥只在 NekoMusic 服务端，客户端永远拿不到，也不应该去拿。

**令牌生命周期**：签发的 access token 带 `sid`，绑定创建它的 Auth 会话族；
会话族过期或被撤销（改密、账号中心撤销设备、显式退出所有设备）后，令牌立即
401。因此：

- 保存的 `refresh_token`（14 天滚动）是唯一的续期凭据；
- 每次启动若令牌距过期不足 1 天，或距上次续期超过 **7 天**，就在后台静默重跑
  步骤 1~5（`prompt=none`，无任何界面）；
- Auth 刷新返回 401（`REFRESH_*`）→ 清本地会话，提示重新输入账号密码；
- 网络失败 / 5xx → 保留登录态，下次再试。

### 扫码登录（保留）

`POST /api/user/qrlogin/create` → 展示返回的 `qrImage`，随后订阅
`GET /api/user/qrlogin/status`（SSE）。收到 `confirmed` 后，用创建响应里的
`deliveryKey` 调 `POST /api/user/qrlogin/claim {sessionId, deliveryKey}` 领取
token；状态帧本身不再携带 token。

`deliveryKey` 只保存在内存（不写二维码 / URL / 日志 / 磁盘），二维码过期、
取消或领取失败时需重新生成。

扫码登录会**清空**账号密码登录保存的 Auth 刷新令牌：静默续期只允许对「最后
登录的账号」生效，避免把两套账号凭据混在一起。

## 请求

普通 API 请求只需要：

```
Authorization: Bearer <token>
User-Agent: NekoMusic-PC/<数字版本>
Accept-Language: zh-CN,zh;q=0.9,en;q=0.8
```

- `Authorization` 是唯一鉴权来源；服务端同时兼容裸 token。
- `User-Agent` 仅用于服务端的 SEO 页面 / SPA 壳表示选择，**不参与鉴权**。
  保持官方锚定的形状只为避免被降级成 HTML。NekoAuth 侧同一个 UA 只会被记进
  「登录设备」的会话信息里（便于用户在账号中心识别这台设备）。
- `Accept-Language` 只影响响应 `message` 文案（zh-CN / zh-TW / en / ja / ko）。

不再发送 `X-Neko-Client-*`、`X-Neko-Nonce`，也不再调用 `/api/client/*` 与
`/api/replay/*`。

### 站点图片（封面 / 头像）

图片经全局 `HttpClient`（浏览器 UA）发起，`Image.network` 以 `add` 语义追加
请求头、无法覆盖 UA，因此图片侧只补：

```
Accept: image/*
Accept-Language: zh-CN,zh;q=0.9,en;q=0.8
```

### 退出

退出登录必须让**本机拿到的全部凭据**同时失效，顺序固定为：

1. `POST /api/user/logout`（Bearer）吊销本机 access token；
2. `POST /api/auth/logout`（带 `Cookie: refresh_token=<刷新型令牌>`）注销
   **账号密码登录建立的 Auth 会话族**——它是 access token 与所有 OAuth
   授权链的根，撤销后派生的令牌立即失效，也不会在服务端残留一个能用
   14 天的刷新令牌；
3. 清空 vault 中的 token / 刷新令牌 / 过期时间 / Auth 地址。

第 2 步只注销「本机这一族」，不影响用户的其它设备与网页登录（那些属于
别的会话族，由用户在各账号中心自行退出）。扫码登录没有 Auth 刷新令牌，
只做第 1、3 步。

**不打开浏览器**，也不调用任何深链。

### 深链

NekoMusic 不使用任何深链回调。`archoera://` 深链（打开播放页 / 搜索 /
专辑 / 歌单 / 歌手）与本音源无关，保持独立；`nekomusic://` 已从三端协议
白名单、macOS `Info.plist` 与命令行解析中删除。

### 已知边界与失效风险

- 账号密码登录依赖 NekoMusic 的**第一方机密客户端**作为 token broker
  （与官方 PC 客户端完全一致）。运营方若收紧 `/api/user/sso/start` 的
  `client` 白名单、或给 `/api/oauth/authorize` 加 Origin / Referer /
  `Sec-Fetch-*` 校验，这条链路会立即失效——此时扫码登录仍然可用。
- **不伪造来源头**：真要收紧时，客户端不会补 `Origin` / `Referer` 去"装成
  第一方页面"。届时可选的正路只有两条：向运营方申请正式客户端（走文档化的
  授权码 + PKCE），或恢复系统浏览器 + 深链回调。已登录的机器不受立刻影响
  （access token 约一年有效，且每 7 天保活会话族），到期或 401 后降级扫码。
- `/api/user/sso/start` 与 `/api/user/sso/claim` 有来源 IP 限流
  （`auth_rate` 的 `login` 档：12 次 / 60 秒），共享出口 IP 下要留意
  `Retry-After`。
- 若未来 NekoAuth 给登录加人机验证 / 两步验证，账号密码链路需要同步适配；
  客户端不绕过任何验证环节。

## 不变量

1. access token 与 Auth 刷新令牌只存凭据保险库（vault 平台键 `neko`），
   不写日志、不进 URL、不进二维码；退出登录时必须先在服务端注销会话族，
   再清本地。
2. **密码只在一次登录请求里出现**，不落盘、不写日志、不放进任何缓存。
3. `deliveryKey` 只保存在内存，不落盘。
4. 二维码只由服务端渲染后下发 PNG，客户端不参与编码或收集额外身份信息。
5. 不伪装浏览器、不冒名 Android；`device` 画像如实上报。
6. 不使用任何 OAuth 客户端密钥，不打开系统浏览器，不注册回调协议。
