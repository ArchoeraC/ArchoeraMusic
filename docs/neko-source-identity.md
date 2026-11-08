# NekoMusic 音源请求与登录方案（NekoAuth）

本文记录 ArchoeraMusic 与 NekoMusic 服务端通信时的**登录与请求**方案，对应实现：
`app/lib/services/neko/neko_api.dart`、`neko_sso_bridge.dart`、
`app/lib/apis/neko/neko_client.dart`、`app/lib/services/deeplink/deep_link_router.dart`。

> 2026-11 起 NekoMusic 服务端移除了 PoW、防重放 nonce 与客户端实例指纹，
> 登录统一改由 **NekoAuth OIDC** 完成。本文描述当前方案；旧实现
> （`neko-client-v1` 实例签名、`/api/replay/*`、`X-Neko-Nonce`）已全部删除。

## 登录

### 原生客户端（PC）：NekoAuth OIDC

1. `POST /api/user/sso/start`，请求体 `{"client":"pc","returnTo":"/"}`；
2. 服务端返回 `data.url`（NekoAuth 授权地址，含一次性 state / nonce / PKCE）；
3. 系统浏览器打开该地址（经 C++ 桥接的 `apl_open_url`，Dart 不直调平台 API）；
4. 授权完成后 NekoAuth 回调 NekoMusic，NekoMusic 打开
   `nekomusic://sso/complete?handoff=<一次性交接码>`；
5. `POST /api/user/sso/claim`，请求体 `{"handoff":"…"}` 取回
   `data.token`（NekoAuth access token）、可选 `data.idToken` 与 `data.user`。

handoff 120 秒有效且只能领取一次；token 不会进入深链、URL 或日志。

### 扫码登录

`POST /api/user/qrlogin/create` → 展示返回的 `qrImage`，随后订阅
`GET /api/user/qrlogin/status`（SSE）。收到 `confirmed` 后，用创建响应里的
`deliveryKey` 调 `POST /api/user/qrlogin/claim {sessionId, deliveryKey}` 领取
token；状态帧本身不再携带 token。

### 账号密码（已下线，保留 UI）

NekoMusic 已删除 `/api/user/login` 等邮箱密码链路。ArchoeraMusic 保留账号密码
界面与调用代码，默认**编译期关闭**：

```bash
flutter build … --dart-define=NEKO_ENABLE_PASSWORD_LOGIN=true
```

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

先 `POST /api/user/logout`（Bearer）吊销 token，再用登录时拿到的 `idToken`
请求 `POST /api/user/sso/logout-url`，把返回的 NekoAuth 注销地址交给系统浏览器
打开；失败只记日志，不影响本地退出。

### 深链回调与单实例

系统打开 `nekomusic://sso/complete` 时可能启动第二个进程。第二实例只做 URI
转发（`apl_deep_link_forward`）后静默退出：Linux 通过会话总线的 `OpenUri`、
Windows 通过隐藏消息窗口的 `WM_COPYDATA`，均带短重试以覆盖首实例启动窗口。
即使转发失败，只要命令行里带深链，也不会再弹「应用已在运行」——避免把登录
回调误判为重复启动。首实例启动后即常驻注册 `OpenUri`（不依赖主题/防休眠订阅），
保证回调能送达。

## 不变量

1. access token / idToken 只存凭据保险库（vault 平台键 `neko`），不写日志、
   不进 URL、不进二维码。
2. `deliveryKey` 只保存在内存，不落盘；handoff 只消费一次。
3. 深链注册（`archoera://` / `nekomusic://`）与浏览器打开都由 C++ 平台桥接
   （`apl_protocol_register` / `apl_open_url`）完成。
4. 不伪装浏览器、不冒名 Android；UA 只复用官方原生客户端的公开形状。
