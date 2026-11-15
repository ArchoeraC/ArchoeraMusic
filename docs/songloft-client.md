# Songloft 流媒体客户端（Go FFI）设计

> 状态：P0/P1 已实施 · 2026-11-15（Go 客户端 + FFI + Dart 映射/会话/表单；
> 服务端逐字/罗马音歌词）
> 范围：流媒体页新增 Songloft 服务器类型；协议实现放在 Go 侧（`app/core/subsonic`
> 模块内的独立包），Dart 经 FFI 调用。**不与本地曲库合并**，不接入本机 Subsonic
> 服务端，不做第三方 Subsonic 客户端兼容；FnOS 不在本期。

## 1. 结论

- Songloft 是自建音乐服务器，核心 API 是 `/api/v1` + JWT，**不是 Subsonic 服务端**
  （服务端 Subsonic 能力另由插件提供，本项目不用）。
- 现有流媒体是独立页面（`app/lib/pages/streaming/`），由
  `StreamingProvider` + `StreamingClient` 驱动，四个 Tab（歌曲/专辑/歌手/歌单）。
- 采用 **Go 客户端 + FFI**：新增 Go 包 `songloft`，编译进现有
  `libarchoera_subsonic` c-shared 库；Dart 新增 `SongloftClient` 分支，复用既有
  `Track` / `StreamingAlbum` / `StreamingArtist` / `StreamingPlaylist` /
  `StreamingLyrics` 模型，不新增 UI 模型。
- 封面由 Go 取二进制并落缓存文件，播放只返回带 `access_token` 的 URL，歌词由
  Go 取回结构化 JSON。
- 凭据（密码 + access/refresh token + 过期时间）全部在凭据保险库
  （`StreamingStore`，uid = `streaming:<serverId>`）；Go 只在内存持有会话。
- 服务器配置沿用流媒体「添加服务器」表单（`StreamingServerConfig` /
  `StreamingServerInput`），只增加一个类型值，不新增配置体系。

## 2. 背景与边界

### 2.1 为什么不是 Subsonic 家族

| 维度 | Subsonic 家族 | Songloft |
|---|---|---|
| 鉴权 | `u/t/s` 盐值 token | `POST /api/v1/auth/login` → JWT，`refresh_token` 续期 |
| 目录 | `getArtists/getAlbum/getAlbumList2/search3` | `/songs` + `/songs/facets` |
| 播放 | `/rest/stream?id=` | `/api/v1/songs/{id}/play` |
| 特征 | 以文件/目录为核心 | 以曲库行 + 聚合维度（facets）为核心 |

把 Songloft 塞进 `StreamingServerType` 的 Subsonic 分支会产生大量协议特判，
因此单独作为一个类型与客户端实现，只复用页面与模型。

### 2.2 为什么放进 Go 侧

- 协议实现集中在一处，Dart 只做「配置 → FFI → 现有模型」的薄映射；
- 与现有 `archoera-subsonic` c-shared 共用构建、加载与日志通道，不新增动态库；
- 后续若要在服务端/命令行复用同一份协议实现，无需搬语言。

### 2.3 明确不做

- 不把 Songloft 曲目并入本地曲库（`library.db`），不走本地扫描/指纹/刮削；
- 不让 Go 的 Subsonic 服务端代理 Songloft 内容；
- 不为第三方 Subsonic 客户端提供兼容；
- 不做 Songloft 的标签、主题、上传、扫描、插件市场等管理能力；
- 不做文件夹浏览（流媒体界面只有歌曲 / 专辑 / 歌手 / 歌单四个 Tab）；
- **不做红心 / 收藏**（与现有流媒体页一致；既不落本地，也不写服务端歌单）；
- **不做播放上报**：`POST /songs/{id}/played` 直接丢弃，不写服务端播放历史；
- **不主动在线抓取歌词**：逐字 / 罗马音只使用服务端返回的 `lxlyric` /
  `rlyric`，没有就退回服务端 `lyric`（或空态）；
- 不做音频代理：播放地址由客户端直连 Songloft。

## 3. 架构

```
Flutter 流媒体页（app/lib/pages/streaming/）
  StreamingProvider（状态 / 四个 Tab / 详情页 / 歌词源）
        │
  StreamingClient（app/lib/services/streaming/streaming_client.dart）
        ├── SubsonicClient（现有）
        ├── JellyfinClient（现有）
        └── SongloftClient（新增）
                │ dart:ffi
                ▼
libarchoera_subsonic（Go c-shared，现有库）
  ├── 现有：Subsonic 服务端（endpoints/db/config/credentials，保持不变）
  └── 新增：songloft 包（纯 HTTP 客户端 + 会话状态）
                │ HTTPS/HTTP
                ▼
Songloft 服务端（/api/v1）
```

边界约束：

1. `songloft` 包不调用 `config.Set`、不打开 `library.db`/`user.db`、不触碰
   `credentials` 包，避免与 Subsonic 服务端状态耦合；
2. 新增独立句柄表（`clientStates`），与现有 `states`（服务端实例）互不影响；
3. 现有 `archoera_subsonic_*` 导出与行为不变，ABI 只增不改。

## 4. 配置与凭据

### 4.1 服务器配置（复用现有表单）

新增 `StreamingServerType.songloft`，显示名 `Songloft`。表单沿用现有字段：

| 字段 | 用途 | 默认 |
|---|---|---|
| `name` | 显示名 | 用户填写 |
| `host` | 主机（IP/域名，不含 scheme） | — |
| `port` | 端口 | `58091`（Songloft 默认端口） |
| `useHttps` | 是否 https | 关 |
| `username` | 登录名 | — |
| `password` | 登录密码（只进 vault） | — |
| `isArchoeraServer` | 对 Songloft 无意义 | 恒 `false`（表单隐藏） |

不新增 `serverPath`：Songloft 支持子路径部署，但现有服务器表单只有 host + port，
本期先不支持子路径（后续如需要再统一给所有类型加路径前缀字段）。

### 4.2 凭据存储

沿用 `StreamingStore`（`streaming_servers.json` 只存非敏感元数据；凭据在
vault，uid = `streaming:<serverId>`）。secret 映射在现有 `password` /
`accessToken` 基础上再扩展两个键：

```text
password       登录密码（首次连接用，已有）
accessToken    JWT access_token（已有，复用）
refreshToken   JWT refresh_token（新增）
tokenExpiresAt 过期时间（Unix 秒，新增；可为空）
```

`StreamingStore.saveSecret` 增加可选 `refreshToken` / `tokenExpiresAt` 参数；
`loadSecret` / `cachedSecret` 原样返回这些键。`StreamingServerConfig` 不新增
token 字段（避免敏感值进入 UI 状态与 `toJson()`）；`SongloftClient` 需要时直接从
`cachedSecret(serverId)` 读取。FFI `open` 配置里的 `expiresAt` 即这里的
`tokenExpiresAt`（仅命名不同）。

### 4.3 连接时序

```text
StreamingProvider.connect()
  → StreamingStore.loadSecret(id)
  → StreamingClient(cfg).ping()            // Songloft 分支
       → SongloftClient.open()             // 组装配置 + vault token
       → FFI: archoera_songloft_open(json)
       → GET /api/v1/version              // 免鉴权，取版本号
       → 若无可用 accessToken：POST /auth/login
       → 事件 ready / error
  → 成功：lastConnected 回填（只写非敏感元数据）
```

### 4.4 token 刷新

- 请求前：`tokenExpiresAt` 剩余不足 60 秒 → 先 `POST /auth/refresh`；
- 请求中：任意接口 401 → 刷新一次并重放（仅一次，避免风暴）；
- 刷新成功 → Go 发 `token` 事件；Dart 收到后写回 vault（合并写，不覆盖密码）；
- 刷新失败 → Go 发 `token-invalid` 事件；本次请求返回 `auth` 错误，UI 提示重新登录。

约束：token 只出现在 Go 内存、HTTP 头/URL 与 vault；日志、异常文案、UI 状态都
不得输出 token；`withoutSecrets()` 语义不变。

### 4.5 会话生命周期

现有 `StreamingClient(cfg)` 是**无状态**的（每次构造只做分发），Subsonic/Jellyfin
可以随用随建；Songloft 的 FFI 会话带 token 与连接池，不能每次构造都重新登录。
因此在 Dart 侧新增按 `serverId` 共享的会话表：

```text
SongloftSessions（Dart，单例）
  serverId → { ffiHandle, pendingRequests, pollTimer, lastError }
```

- `StreamingProvider.connect()`：打开会话（幂等）；
- `disconnect()` / `removeServer()` / `clearAll()` / 应用退出：关闭会话并丢弃 token；
- `StreamingClient` 的 Songloft 分支每次调用时 `SongloftSessions.of(cfg)` 取会话；
  未打开则按需打开（例如详情页先于设置页访问时）；
- 切换激活服务器时**不立即关闭**旧会话（用户可能切回），由显式断开或删除触发关闭；
- 同一 `serverId` 只允许一个句柄，避免 token 双份刷新；
- 已接入 `StreamingProvider`：`disconnect` / `removeServer` / `updateServer` /
  `clearAll` 都会关闭对应会话（打开中的会话在就绪后立即关闭）。

## 5. FFI 契约（草案）

### 5.1 导出函数

| 导出 | 签名 | 说明 |
|---|---|---|
| `archoera_songloft_open` | `(const char *configJson) -> intptr_t` | 创建会话，返回句柄；`0` 失败 |
| `archoera_songloft_close` | `(intptr_t h)` | 关闭会话，丢弃内存 token |
| `archoera_songloft_call` | `(intptr_t h, const char *requestJson) -> int` | 入队异步请求；返回 0 表示已受理，负数表示参数/句柄错误 |
| `archoera_songloft_take_event` | `(intptr_t h, int *outLen) -> char*` | 取一条事件 JSON；无事件返回 `NULL`、`*outLen = 0` |
| `archoera_songloft_free` | `(void *p)` | 释放 `take_event` 返回的字符串 |

说明：

- 事件 JSON 由 Go `C.malloc`/`C.CString` 分配，Dart 读完必须调 `free`；避免现有
  `copyToBuf` 的 4 KB 截断（目录列表远大于 4 KB）；
- `call` 只入队，立即返回；网络在 Go goroutine 执行，**不阻塞 Dart isolate**；
- 同一句柄允许并发多个请求，用 `id` 关联结果；
- `close` 后所有未完成请求由 Dart 侧按 `id` 统一失败（`canceled`）。

### 5.2 `open` 配置

```json
{
  "serverId": "uuid",
  "scheme": "http",
  "host": "192.168.1.10",
  "port": 58091,
  "username": "alice",
  "password": "…",
  "accessToken": "…",
  "refreshToken": "…",
  "expiresAt": 1760000000,
  "coverCacheDir": "/home/alice/.local/share/ArchoeraMusic/cache/songloft_covers",
  "requestTimeoutMs": 30000
}
```

`coverCacheDir` 由 Dart 传入（`resolveDataDir()/cache/songloft_covers`），Go 负责
校验/创建目录并写入 `<dir>/<serverId>/<kind>-<id>.img`。

### 5.3 请求方法

`requestJson`：

```json
{ "id": "dart-递增序号", "method": "listSongs", "params": { } }
```

| method | params | result.data |
|---|---|---|
| `version` | `{}` | `{version,full}`（已缓存则直接回） |
| `login` | `{}` | `{}`（成功后随事件回 token） |
| `listSongs` | `{offset,limit,sort,order,keyword?,album?,artist?,genre?}` | `{total,limit,offset,songs:[Song]}` |
| `listAlbums` | `{offset,limit,keyword?,sort?,order?}` | `{total,facets:[{value,count,coverSongId}]}` |
| `listArtists` | 同上，`field=artist` | 同上 |
| `listPlaylists` | `{offset,limit}` | `{total,playlists:[Playlist]}` |
| `getPlaylistSongs` | `{playlistId,offset,limit,sort?,order?}` | `{total,songs:[Song]}` |
| `getStreamUrl` | `{songId,quality}` | `{url}` |
| `getLyrics` | `{songId}` | `{lyric,tlyric,rlyric,lxlyric}`（无歌词返回空对象） |
| `getCover` | `{kind:"song"\|"playlist", id}` | `{path,contentType,bytes,cached}` |

`getStreamUrl` 的 `quality` 映射（与现有档位一致）：

| UI 档位 | Songloft 参数 |
|---|---|
| `original` | 无参数（原文件） |
| `high` | `format=mp3&quality=320` |
| `medium` | `format=mp3&quality=192` |
| `low` | `format=mp3&quality=128` |

URL 末尾附 `access_token=<当前 token>`（Songloft 支持 query 鉴权），
与现有 Subsonic 封面/流 URL 的「鉴权进 URL」模型一致。

### 5.4 事件

`take_event` 每次返回一条 JSON：

```json
{"type":"result","id":"12","ok":true,"data":{...}}
{"type":"result","id":"13","ok":false,"error":{"code":"auth","message":"…"}}
{"type":"token","accessToken":"…","refreshToken":"…","expiresAt":1760000000}
{"type":"token-invalid","message":"…"}
{"type":"ready","version":"2.x.y"}
{"type":"error","message":"…"}
```

错误码（`error.code`）：`auth` / `network` / `timeout` / `not-found` /
`protocol` / `canceled`。Dart 映射到现有 `StreamingAuthError` /
`StreamingHttpError` / `StreamingTimeoutError`，UI 文案沿用现有错误组件。

### 5.5 内存与线程

- 请求 JSON：Dart `toNativeUtf8()` 分配，Go `C.GoString` 复制后立即返回；
- 结果/事件：Go 分配，Dart `archoera_songloft_free` 释放；
- HTTP 客户端：每个会话一个 `http.Client`（连接复用），`close` 时关闭；
- 超时：默认 30 s（与 `streamingRequestTimeout` 一致），由 Go 的
  `context.WithTimeout` 实现；
- 日志：走现有 `logging` sink（`archoera_subsonic_set_log_sink`），不打 token。

## 6. 数据映射（Songloft → 现有模型）

字段来源：`GET /api/v1/songs`、`/songs/facets`、`/playlists`、`/songs/{id}/lyric`。

### 6.1 Song → `Track`

| `Track` 字段 | 来源 | 说明 |
|---|---|---|
| `id` | `'$serverId:$song.id'` | 与 Subsonic 的 `${serverId}:${originalId}` 同构 |
| `originalId` | `song.id`（int64 → string） | 播放时回传 FFI |
| `serverId` | 配置 id | |
| `title` / `artists` / `album` | `title` / `artist` / `album` | Songloft 给单字符串：整串塞进一个 `TrackArtist`，按它自身的展示串处理（不拆多歌手）；专辑无独立 id，`TrackAlbum.id` 置空 |
| `duration` | `duration`（秒，float） × 1000 | 现有模型为毫秒 |
| `cover` | 封面缓存文件绝对路径 | 由 `getCover` 写盘后返回 |
| `fileSize` | `file_size` | |
| `quality.sampleRate` | `sample_rate` | |
| `quality.bitRate` | `bit_rate`（kbps） × 1000 | 现有模型为 bps |
| `quality.codec` | `format` | `mp3` / `flac` / … |
| `source` | `'streaming'` | 与现有流媒体一致 |

`cover` 的取法：映射时先看缓存文件是否存在；不存在则先用带 `access_token`
的直链（保证首屏立即可见），同时在后台对前 24 项调用 `getCover` 让 Go 取二进制
写盘，下次刷新/重进即走本地路径。

### 6.2 Facet → `StreamingAlbum` / `StreamingArtist`

| 模型 | 映射 |
|---|---|
| `StreamingAlbum.id` | facet `value`（专辑名） |
| `StreamingAlbum.name` | `value` |
| `StreamingAlbum.trackCount` | `count` |
| `StreamingAlbum.cover` | `coverSongId` → `getCover` 缓存路径 |
| `StreamingArtist.id` | facet `value`（歌手名） |
| `StreamingArtist.name` | `value` |
| `StreamingArtist.avatar` | facet `coverSongId` → 封面缓存路径 |
| `StreamingArtist.albumCount` | `null`（facets 只给歌曲数，不给专辑数；UI 自动隐藏副标题） |

专辑/歌手详情没有独立端点，由 `/songs?album=<name>` / `?artist=<name>` 过滤，
对应 `StreamingClient.getAlbumSongs` / `getArtistSongs`；`getArtistAlbums` 返回空
列表（详情页只展示歌曲）。

### 6.3 Playlist → `StreamingPlaylist`

| 字段 | 来源 |
|---|---|
| `id` | `playlist.id`（int64 → string） |
| `name` | `name` |
| `description` | `description` |
| `trackCount` | `song_count` |
| `cover` | `playlist.cover_url` 非空 → `getCover` 缓存；否则占位 |

`GET /playlists` 默认排除 `hidden`；`built_in` 收藏歌单按普通歌单展示（v1 不做
「我喜欢」语义）。

### 6.4 歌词 → `StreamingLyrics`

`GET /songs/{id}/lyric` 返回：

```json
{"lyric":"[00:12.00]…","tlyric":"…","rlyric":"…","lxlyric":"…"}
```

- `lyric` → `StreamingLyrics.lrc`（标准歌词）；
- `lxlyric` → `wordByWord`，并按内容标注 `wordFormat`（`<偏移,时长>` → `yrc`，
  行头 `[起始,时长]` → `qrc`）；没有逐字标记时不启用；
- `tlyric` / `rlyric` → `translation` / `romaji`，格式各自标注（`lrc`/`yrc`/`qrc`）；
- 格式选择交给 `pickLyricFormat`：`preferRich` 时逐字优先，否则标准歌词优先；
  两者都空才返回空 `StreamingLyrics`；
- 服务端可能返回传统 YRC / 新版 YRC（`[ms,dur](start,dur,flag)字`）/ QRC /
  非标准 `[ms,dur]` 行头；歌词来源层统一归一化为引擎可解析的文本
  （`normalizeStreamingWordLyric`），不改动歌词语义；
- 404 或全空 → 返回空 `StreamingLyrics`，不报错；
- **只使用服务端提供的字段**，客户端不会为逐字/罗马音另行发起在线请求。

## 7. 页面与交互

- 四个 Tab 复用现有视图：歌曲（`songs_tab`）、专辑（`albums_tab`）、歌手
  （`artists_tab`）、歌单（`playlists_tab`）；
- 分页沿用现有策略：单页 500，循环拉到不足一页为止（`_kMaxPages` 保护）；
- 详情页复用 `album_detail` / `artist_detail` / `playlist_detail`；
- 播放：`SourcePlatform` 的 streaming 分支调用 `getStreamUrl`，返回 URL 直接交给
  播放器；现有转码探测（`_streamTranscodeUsable`，Range 取 64B）对 Songloft 同样
  适用：探测失败即回退 `original`，与服务端行为一致；
- 歌词：`streaming_lyric_source` 走 `StreamingClient.getLyrics`，逐字 / 翻译 /
  罗马音都只取服务端字段；
- 封面：`Track.cover` 为本地缓存路径，`CoverImage` 已支持绝对路径；
- 表单：类型选 Songloft 且端口为空时默认填 `58091`（其余类型行为不变）。

搜索：流媒体页沿用**自带的独立搜索**（歌曲 Tab 的本地过滤），不接入全局搜索，
也不新增服务端搜索入口（与现有流媒体一致）。


## 8. 失败与重试

| 场景 | 行为 |
|---|---|
| 登录失败 | `auth` 错误，UI 提示检查用户名/密码；不清除已存配置 |
| token 过期 | 自动 refresh 一次；失败 → `token-invalid` → UI 提示重新登录 |
| 网络失败 | `network` 错误；不重试（用户可手动刷新/重连） |
| 超时 | 30 s 超时 → `timeout`；封面请求 15 s |
| 歌词 404 | 返回空歌词，不弹错 |
| 封面失败/不存在 | 返回空路径，UI 占位图 |
| 服务端限流（登录） | 透传提示，不自动重试 |

## 9. 兼容与版本

- 连接时先用 `GET /api/v1/version` 拿版本号（免鉴权），写入
  `StreamingState.serverVersion`；
- v1 依赖的端点（`/auth/login`、`/auth/refresh`、`/songs`、`/songs/facets`、
  `/playlists`、`/songs/{id}/play|cover|lyric`、`/version`）在 2.x 已提供；是否
  存在以 `/version` 与首次请求的实际结果为准，缺失时按空结果降级；
- 文件夹浏览（`/songs/folders`，2.12.1+）不在本期；
- 服务端不支持的端点（如未启用歌词插件）按空结果处理，不阻断浏览。

## 10. 分阶段

### P0（本期）

1. Go：`songloft` 包（配置、会话、登录/刷新、songs/facets/playlists、播放 URL、
   歌词、封面下载与缓存写盘、错误归一化）；
2. Go：`archoera_songloft_*` FFI 导出 + 事件队列 + 单测（httptest 假服务端）；
3. Dart：`SongloftClient` + `StreamingClient` 分支 + `StreamingServerType.songloft`
   + 类型标签/表单（默认端口 58091）+ `StreamingStore.saveSecret` 扩展；
4. 流媒体页四 Tab、详情页、歌词、封面缓存、连接/重连。

### P1（已实施）

- 逐字（`lxlyric`）/ 翻译（`tlyric`）/ 罗马音（`rlyric`）歌词（仅服务端提供时）；
- 流媒体页自带独立搜索保持现状（不接全局搜索）；
- 播放上报丢弃。

### 不做（与现有流媒体保持一致）

现有流媒体页没有的能力，Songloft 也不新增：

- 红心 / 收藏（含服务端 `built_in` 歌单）；
- 歌单写操作（新建 / 改名 / 删除 / 加移曲）；
- 标签、排序偏好、服务端搜索入口；
- 文件夹浏览；
- 播放上报（`/songs/{id}/played`）。

## 11. 测试

- Go 侧：`httptest` 假 Songloft，覆盖登录/刷新/401 重放/分页/错误码/超时/
  封面落盘；**默认不联网**，真实服务器用例以 `ARCHOERA_ONLINE_TEST=1` 显式启用；
- Dart 侧：`songloft_client_ffi_test.dart` 用真实 c-shared + 本机假服务端，
  覆盖登录、目录、播放 URL、歌词（含逐字/翻译/罗马音）、封面落盘；
  库未构建/缺符号时自动跳过；
- 回归：`cd app && dart analyze lib && flutter test`；改 Go 后跑
  `cd app/core/subsonic && go test ./...`（按仓库约定，测试只在本机跑）。

## 12. 风险与对策

| 风险 | 对策 |
|---|---|
| FFI 事件轮询延迟 | 仅在有未完成请求时启动 20 ms 定时器；空闲即停 |
| 大 JSON 事件 | `take_event` + 显式 `free`，不复用 4 KB 定长缓冲 |
| token 写回 vault 时序 | `token` 事件合并写；vault 不可用时保留内存态并告警，不阻断播放 |
| 封面缓存膨胀 | 按 `<serverId>/<kind>-<id>.img` 命名；后续增加容量上限与 LRU 清理 |
| 大曲库 facets 成本 | 分页（默认 20，单次上限 100000）；列表页只拉首屏 |
| 服务端 API 漂移 | 错误归一化 + `version` 探测；端点缺失按空结果降级 |
| Go 库体积/启动 | 复用现有 c-shared，无新增动态库；客户端代码不引第三方依赖 |

## 13. 实施记录（2026-11-15）

1. 事件消费采用 `take_event` 轮询（20ms，仅在有未完成请求/等待就绪时运行），
   大 JSON 用 `take_event` 返回的 `char*` + `archoera_songloft_free`；
2. 封面缓存：`<dataDir>/cache/songloft_covers/<serverId>/<kind>-<id>.img`，
   P0 不做容量上限；
3. 流媒体不做红心 / 收藏（与现有流媒体页一致），播放上报直接丢弃；
4. Go 单测：`app/core/subsonic/songloft/client_test.go`（httptest 假服务端，
   覆盖登录/刷新/401 重放/分页/歌词 404/封面落盘）；
5. Dart 端到端：`app/test/songloft_client_ffi_test.dart`（真实 c-shared + 本机
   假服务端；库未构建/缺符号时自动跳过）；
6. 注意：`StreamingProvider` 已接入会话关闭；`StreamingStore` 的
   `refreshToken` / `tokenExpiresAt` 与 `accessToken` 一样只进 vault。
