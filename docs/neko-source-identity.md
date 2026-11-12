# NekoMusic 音源请求与登录方案（仅扫码）

本文记录 ArchoeraMusic 与 NekoMusic 服务端通信时的**登录与请求**方案，对应实现：
`app/lib/services/neko/neko_api.dart`、`app/lib/apis/neko/neko_client.dart`。

> **破坏性变更（2026-11-09）**：NekoAuth OAuth（浏览器授权 + `nekomusic://`
> 深链回调）、传统邮箱密码登录与「忘记密码」入口已**整体移除**。客户端现在
> 只保留扫码登录，不再调用 `/api/user/sso/*`、`/api/user/login`，也不再注册
> `nekomusic://` 协议，相关 C ABI（`apl_open_url` / `APL_CAP_OPEN_URL`）同步删除。
> 旧版本升级后需要重新用手机 App 扫码登录（vault 中已有的 token 仍可继续使用）。

## 登录

### 扫码登录（唯一方式）

`POST /api/user/qrlogin/create` → 展示返回的 `qrImage`，随后订阅
`GET /api/user/qrlogin/status`（SSE）。收到 `confirmed` 后，用创建响应里的
`deliveryKey` 调 `POST /api/user/qrlogin/claim {sessionId, deliveryKey}` 领取
token；状态帧本身不再携带 token。

`deliveryKey` 只保存在内存（不写二维码 / URL / 日志 / 磁盘），二维码过期、
取消或领取失败时需重新生成。

## 请求

普通 API 请求只需要：

```
Authorization: Bearer <token>
User-Agent: NekoMusic-PC/<数字版本>
Accept-Language: zh-CN,zh;q=0.9,en;q=0.8
```

- `Authorization` 是唯一鉴权来源；服务端同时兼容裸 token。
- `User-Agent` 仅用于服务端的 SEO 页面 / SPA 壳表示选择，**不参与鉴权**。
  保持官方锚定的形状只为避免被降级成 HTML。
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

先 `POST /api/user/logout`（Bearer）吊销 token，再清理本地会话；**不打开浏览器**。
NekoAuth 的浏览器会话（如果用户曾自行在网页端登录）由用户在账号中心退出；
应用内退出只处理自己的 token。

### 深链

NekoMusic 不再使用任何深链回调。`archoera://` 深链（打开播放页 / 搜索 /
专辑 / 歌单 / 歌手）与本音源无关，保持独立；`nekomusic://` 已从三端协议
白名单、macOS `Info.plist` 与命令行解析中删除。

## 不变量

1. access token 只存凭据保险库（vault 平台键 `neko`），不写日志、不进 URL、
   不进二维码。
2. `deliveryKey` 只保存在内存，不落盘。
3. 二维码只由服务端渲染后下发 PNG，客户端不参与编码或收集额外身份信息。
4. 不伪装浏览器、不冒名 Android；UA 只复用官方原生客户端的公开形状。
