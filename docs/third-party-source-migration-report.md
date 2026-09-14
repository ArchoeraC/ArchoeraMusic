# 第三方音源移植报告（baka-plugins / go-music-dl → ArchoeraMusic）

> 状态：调研稿 v1 · 2026-09-14
> 范围：`baka-plugins`（JS 插件集）与 `go-music-dl`（Go 多源工具）对 ArchoeraMusic
> 在线音乐（第三方平台接入）的可移植性评估、目标架构与分阶段落地清单。
> 结论导向：**因三端架构完全不同（主项目 = 纯 Dart 平台协议层 + FFI 原生模块、零侧车），
> 两个项目都只能「移植」——即参考其协议与接口设计，在 Dart 侧重实现；不引入运行时、不整包移植。
> 且硬约束：任何数据不得经过官方平台以外的第三方（见 §8.1）。**

---

## 0. 结论速览（TL;DR）

1. **架构不同 → 只能移植，不能引入**：
   - `baka-plugins` 是 **Node/CommonJS 运行时**，且 **未声明任何许可证**（`package.json` 无 `license` 字段，仓库无 `LICENSE`）——命中
     `CONTRIBUTING.md` §2.2「禁止非 FFI 大运行时」与 §9「许可必须可溯、登记」，**不可复制代码**。
   - `go-music-dl` 是 **Go 程序**（AGPL-3.0，许可兼容），但其真正协议实现位于外部依赖
     `github.com/guohuiyuan/music-lib`（**未随仓库分发、未在本地 module cache**）；引入 Go 运行时同样命中
     §2.2/戒律 #11，且 §2.2 明确「高度不建议第三方『预制菜』整包引入」。**不可作为业务载体**。
   - 主项目在线音乐是**纯 Dart 直连**（戒律 #2，`app/lib/apis/` + `app/lib/services/<platform>/`），
     与上述两项目的进程/插件模型不兼容；**唯一可行路径是把协议与设计移植为 Dart**。
2. **真正的价值是「协议知识库 + 统一接口范式」**：两个项目覆盖的平台/端点/签名算法，正好补齐 ArchoeraMusic
   目前只有 **netease / kugou / qqmusic** 三家的缺口；它们的 `Song`/`Provider` 模型也为主项目
   重构「散落 switch」提供了现成参考。
3. **建议路线**：
   - **P0（先做）**：把主项目现有的「按 `source` 字符串 switch」收敛为纯 Dart 的
     `OnlineSource` 接口 + `OnlineSourceRegistry`（行为零回归），并给 `Track` 增加通用 `extra` 载荷。
   - **P1**：用两个项目的实现补强现有 QQ / 酷狗 / 网易云（QQ 桌面搜索 `zzcSign`+`ct=19`、酷狗全局歌单、
     网易云 YRC/eapi 歌词与 `trackIds` 缓存等）。
   - **P2（新增，性价比最高）**：**酷我 kuwo**、**咪咕 migu**（baka 有完整可读 JS，go-music-dl 有 Go 对照）。
   - **P3**：Bilibili、千千、5sing、Jamendo、JOOX、Apple（小众/受限，按需）。
   - **P4（官方路径可做）**：汽水（soda/qishui）。业务/内容请求本就全走官方域名
     （`api.qishui.com`、`beta-luna.douyin.com`、`music.douyin.com`、`api5-lf.qishui.com`）。
     两处非「汽水官方」域名：X-Headers 签名服务 `api.music.qishui.vsaa.cn`（**个人第三方**），
     以及 `api-vehicle.volcengine.com`（字节火山引擎内容接口，**字节官方云但非汽水官方**）。
     按硬约束（第 7 条）**两者均不接入**：只走**纯官方 PC API + SEO** 路径，暂不提供**无损/空间音频**
     （**逐字歌词不受影响**：官方 SEO 实测返回 KRC，见 §7-P4）；除非日后**本地实现签名**直连官方。
     **完整登录（扫码 + 短信 MFA）实测可纯 Dart HTTP 完成**——按 `music-lib/soda/login.go`
     的参数，`get_qrcode`/`check_qrconnect` **免 `a_bogus`/`msToken`/浏览器**即通
     （不引 WebView / JS 运行时；滑块/人脸不可，见 §7-P4）。详见 §7-P4 / §8.1。
   - **P5（后期 R&D）**：**本地签名 + 下载增强**（解密/标签内嵌）——彻底去第三方，
     补齐全量官方能力。先做算法明确的（Bilibili WBI、千千、酷我、咪咕），
     ByteDance `x-gorgon` 等高风险项按需投入。详见 §7-P5。
4. **合规动作**：所有参考移植须在 PR 说明来源，并在对应模块 `THIRD-PARTY-LICENSES.md` 登记
   `baka-plugins`（无许可，仅作协议事实参考，不复制表达）与 `go-music-dl` / `music-lib`（AGPL-3.0）。
5. **请求去向审计（§10）**：两个项目的**业务请求全部直达平台官方域名**；唯一第三方是 baka
   源插件的**播放 URL 聚合服务**（只收 `{source, songId, quality}`，无凭据）——主项目应改用官方取流、
   **不移植该聚合层**；汽水签名服务能读到 `sessionid`，按 §7-P4 隔离。故平台接入无红线障碍。
6. **第三方网关实测（§11）**：对 baka 各音源端点做了无凭据探测——它们都只是**官方 CDN 直链网关**
   （多数 302/返回官方 URL），且有卡密/限速/试听阉割/易失效问题；**无独立价值**，
   仅作官方取流的参数对照，**按硬约束一律不接入**。
7. **硬约束（本次确认）**：**任何数据都不得经过官方平台以外的第三方**。因此——
   - baka 的第三方音源网关（ikun/linglan/cihedai/changqing/quandouyao/hyw）**一律不接入**；
   - 汽水签名服务 `vsaa.cn`（个人第三方）与 `api-vehicle.volcengine.com`（字节云，非汽水官方）
     **不得出现在请求链路上**（只能走纯官方路径，见 §7-P4）；
   - 两项目**只作为「官方协议实现」的参考**；新增平台的解析能力必须**直连官方**（见 §8.1 映射表）。
8. **按需加载 / 即时卸载（§6.5）**：平台变多后**不能启动即构造全部 facade**；注册表用
   「工厂懒构造 + 租约引用计数 + 空闲 TTL 卸载 + 任务互斥」，并解除 `bootstrap` 的全量实例化。
   `deferred as` 在桌面不可靠，不作为方案；靠运行时对象生命周期。

---

## 1. 三项目总览

| 项 | ArchoeraMusic（主项目） | baka-plugins | go-music-dl |
|---|---|---|---|
| 形态 | Flutter 桌面播放器 | 音源插件分发服务（Netlify/Vercel/Express） | Go CLI + Web + 桌面壳 |
| 语言/运行时 | Dart（业务）+ C/C#/C++/Rust/Go（FFI 原生模块） | Node.js / CommonJS | Go 1.25 |
| 在线音乐协议位置 | `app/lib/apis/<platform>/` + `app/lib/services/<platform>/` | 每个 `plugins/*.js` 自包含 | 外部依赖 `music-lib/*`（本仓库只做编排） |
| 已接入平台 | netease、kugou、qqmusic（+ streaming：Subsonic/Jellyfin） | wy、kg、kw、qq、mg、bilibili、qishui | netease、qq、kugou、kuwo、migu、fivesing、jamendo、joox、qianqian、soda、bilibili、apple |
| 许可 | AGPL-3.0-or-later | **无许可证声明** | AGPL-3.0（music-lib 同源） |
| 对主项目的直接可用性 | — | 仅协议参考 | 仅协议/设计参考 |

> 说明：本报告中 `go-music-dl` 自身的文件（`core/`、`internal/web/`）已本地核对；
> `music-lib` 的具体端点/算法来自其公开说明与通用知识，**移植前必须以实际拉取的 `music-lib` 源码为准**。

---

## 2. 主项目现状（在线音乐）

### 2.1 三层结构

每个平台都由三层组成（以 netease 为例）：

| 层 | 路径 | 职责 |
|---|---|---|
| 协议/加密/请求 | `app/lib/apis/<platform>/core/*` | 纯签名 + HTTP，返回原始 `Map` |
| 模块注册表 | `app/lib/apis/<platform>/modules/*` + `modules/index.dart` | 按字符串 key 分发的端点函数 |
| 领域门面 | `app/lib/services/<platform>/*` | 解析为 `Track`/`CoverItem`，持有登录态，暴露 `resolvePlayUrl` 等 |

共享注入缝：`app/lib/apis/runtime.dart` 的 `ApisRuntime`（`SessionStore`/歌词缓存/`getSetting`），
启动时在 `app/lib/main.dart` 注入；会话统一走 `getRuntime().sessionStore`。

### 2.2 统一模型

- `Track`：`app/lib/services/netease/track.dart:309`（全局模型，虽在 netease 目录下）。
  - `String source`（`'netease'|'kugou'|'qqmusic'|'local'|'streaming'`，`track.dart:349`）
  - 平台子载荷：`KugouTrackInfo? kugou`（`track.dart:58`）、`QqMusicTrackInfo? qqmusic`（`track.dart:178`）
  - `fromNeteaseSong` / `fromKugouSong` / `fromQqMusicSong` / `fromJson` / `toJson`
- 搜索用轻量模型 `CoverItem`（`app/lib/services/netease/netease_api.dart:57`）、`SearchResult<T>`（同文件 :44）
- 流媒体有独立抽象：`StreamingClient`（`services/streaming/streaming_client.dart:78`）+
  `StreamingServerType` 枚举（`services/streaming/streaming_types.dart:12`）——**这是主项目里唯一
  「接口化」的在线源范式，应作为新源架构的模板**。

### 2.3 关键痛点：平台分发是散落的字符串 switch

没有任何 `OnlineSource` 接口；`Track.source` 的分发在以下位置重复实现（新增平台必须逐处改）：

| 位置 | 文件:行 | 作用 |
|---|---|---|
| 播放源解析 | `services/playback/playback_notifier/playback_notifier_queue.dart:11` (`_resolveSource`) | 核心分发 |
| 音质切换 | `services/playback/playback_notifier/playback_notifier_loading.dart:263` (`setQuality`) | 平台 → URL |
| 歌词 | `stores/lyrics_provider.dart:40` (`switch (track.source)`) | 平台 → 歌词 |
| 红心 | `stores/like_controller.dart:93/105/179/274` | 平台 → 点赞 |
| 搜索页 | `pages/search/search_page_view.dart:184`、`pages/search/search_page_models.dart:60` | 平台 tab / 聚合 |
| 下载 | `services/downloader/download_controller/...`、`widgets/dialogs/track_context_menu/...` | 平台过滤 |
| 登录弹窗 | `widgets/dialogs/{netease_login_dialog,kugou_login_button,qqmusic_login_dialog}.dart` | 各写一套 |

> 结论：新增平台的真实成本不在协议本身，而在**这 7 类注册点**。P0 重构的核心就是把它收敛成注册表。

### 2.4 已有能力（可复用底座）

- `ApisRuntime`（`apis/runtime.dart`）：会话/歌词缓存注入。
- `LruCache`（`apis/lru_cache.dart:21`）：响应缓存。
- 歌词匹配层 `app/lib/apis/lyric/`（`types.dart` 的 `LyricCandidate`/`LyricMatchResult`、
  `fingerprint.dart`、`utils.dart` 的 `pickBestCandidate`、`ttml.dart`）。
- 加密依赖已具备：`pointycastle ^4.0.0`、`crypto ^3.0.6`（`app/pubspec.yaml:51`）。
  zlib 可用 `dart:io` 的 `ZLibCodec`；**gb18030 解码目前无依赖**（酷我歌词需要，见 §5.4）。

---

## 3. baka-plugins 解析

### 3.1 架构

- `functions/plugin.js`：分发单个插件脚本，并向「源插件」注入 `requestMusicUrl(source, songId, quality)`
  （由 `apiType` 生成不同音源 API 调用）。
- `functions/source-config.js`：`SOURCE_CONFIG` 音源注册表（ikun/linglan/cihedai/changqing/quandouyao/hyw），
  含 `requiresKey`、`apiType`、每插件音质覆盖。
- `functions/subscription.js`：扫描 `plugins/` 返回订阅清单。
- `plugins/*.js`：平台协议自包含。`FREE_PLUGINS = ['bilibili.js','qishui.js','mg.js']`（自解析 URL），
  其余为「源插件」（URL 由第三方音源 API 出）。

### 3.2 插件契约（可直接借鉴为 Dart 接口）

每个插件 `module.exports` 暴露（全部可选，除 `search`）：

```
search(query, page, type) -> { isEnd, data: Item[] }        // type: music|album|sheet|artist|lyric
getMediaSource(item, quality) -> { url, headers?, quality?, cek? }
getMvSource(item, videoQuality) -> { url, headers?, ... }
getMusicInfo(base) -> item
getLyric(item) -> { rawLrc, translation?, romanization?, artwork? }
getAlbumInfo(album, page?) -> { albumItem?, musicList }
getArtistWorks(artist, page, type) -> { isEnd, data }       // type: music|album
getArtistInfo(artist) -> ...
importMusicSheet(urlLike) -> sheet
importMusicItem(urlLike) -> item
getMusicSheetInfo(sheet, page) -> { isEnd, sheetItem?, musicList }
getRecommendSheetTags() -> { pinned, data }
getRecommendSheetsByTag(tag, page) -> { isEnd, data }
getTopLists() -> [{ title, data: [...] }]
getTopListDetail(topListItem) -> { ..., musicList }
getMusicComments(item, page) -> { isEnd, data: Comment[] }
getMusicDetailPageUrl(item) -> string
```

元数据字段：`platform / author / version / appVersion / primaryKey / supportedQualities /
supportedVideoQualities / userVariables / hints / supportedSearchType`。
统一音质词表：`mgg,128k,192k,320k,flac,flac24bit,hires,atmos,atmos_plus,master,dolby`。
分页契约（`docs/playlist-import-pagination.md`）：**分页是插件责任；失败必须抛错而非截断**；
`worksNum`（源总数）与 `musicList.length`（实取数）可不等。

### 3.3 各平台端点与加密（移植参考）

| 插件 | 关键 Host | 签名/加密 | 独有价值 |
|---|---|---|---|
| `qq.js` | `u.y.qq.com/cgi-bin/musicu.fcg`、`musics.fcg`、`c.y.qq.com` | `zzcSign`（SHA1 + 索引取字 + XOR + base64，`qq.js:315`）；`ct=19` 取全量 `size_hires`（`qq.js:179`） | 桌面签名搜索、专辑/榜单分页（999/页）、MV、评论 |
| `wy.js` | `music.163.com/weapi`、`interface3.../eapi`、`/api` | weapi AES-CBC+RSA（`getParamsAndEnc` :80）、eapi AES-ECB（:22） | eapi 歌词、YRC→QRC、批量音质、`trackIds` 本地缓存（:430）、榜单 HTML |
| `kg.js` | `songsearch/mobilecdn/gateway.kugou.com/lyrics.kugou.com` | `signatureParams` MD5（:525）、KRC XOR+pako（:419） | 全局收藏歌单（`get_other_list_file_nofilt`）、酷狗码解析、分享歌单 |
| `kw.js` | `search.kuwo.cn`、`nplserver.kuwo.cn`、`newlyric.kuwo.cn` | `yeelion` XOR+base64（:656）、歌词 pako + **gb18030**（:437） | 完整酷我客户端（搜索/歌单/专辑/歌手/MV/榜单/评论） |
| `mg.js` | `c.musicapp.migu.cn`、`jadeite.migu.cn` | 搜索 MD5 签名（:463）、策略响应自定义解密（:89）、MRC TEA（:589） | 完整咪咕客户端；URL 策略解密+多档回退 |
| `bilibili.js` | `api.bilibili.com` | WBI（:209）、ticket HMAC-SHA256（:223）、Cookie 登录 | DASH 音频选择、收藏夹、字幕当歌词、WBI 空间投稿 |
| `qishui.js` | `api.qishui.com`、`beta-luna.douyin.com` | **外部 X-Headers 签名服务**（:37/:485）、Spade PlayAuth 解密（:291） | 汽水（抖音）搜索/播放/歌单；**隐私风险见 §8** |

### 3.4 对主项目的可移植点

- 契约模型（§3.2）→ 直接映射为 Dart `OnlineSource` 接口。
- 音质词表与 `supportedQualities` → 主项目 `qualityBitrate`/`qualityLabels` 的扩展依据。
- 分页契约 → 主项目歌单导入/`SearchResult.hasMore` 的语义规范。
- QQ/KG/NT 的新端点与算法 → P1 补强；KW/MG/Bilibili → P2/P3 新源。

---

## 4. go-music-dl 解析

### 4.1 架构（本地已核对）

- `core/`：源工厂（`GetSearchFunc` `service.go:148` 等）、Cookie 管理（`CookieManager` `:53`）、
  下载管线（`download.go`）、元数据内嵌（`service.go:1589` `EmbedSongMetadata`）、WebDAV、下载记录去重。
- `internal/web/`：Gin HTTP 服务，路由见 `RegisterMusicRoutes`（`music.go:352`）、`RegisterQRLoginRoutes`
  （`qr_login.go:50`）、本地歌单/本地音乐/视频生成/更新。
- `cmd/music-dl`：Cobra CLI；`cmd/search-server`：独立 JSON 搜索服务。
- **平台协议在外部 `music-lib`**：`core/service.go:24-37` 直接 import
  `music-lib/{netease,qq,kugou,kuwo,migu,fivesing,jamendo,joox,qianqian,soda,bilibili,apple}`。

源清单（`core/service.go:1005`）：
`netease, qq, kugou, kuwo, migu, fivesing, jamendo, joox, qianqian, soda, bilibili, apple, local`；
默认源（`GetDefaultSourceNames` `:1021`）排除 `bilibili/joox/jamendo/fivesing/local`；
QR 登录源（`:402`）`netease, qq, qq_wx, kugou, bilibili`；
用户歌单源（`:422`）`netease, qq, kugou, soda`。

### 4.2 可借鉴的接口设计（music-lib `provider/interface.go`）

`SongSearcher / SongParser / SongDownloader / LyricProvider / MusicProvider / AlbumProvider /
PlaylistProvider / RecommendedPlaylistProvider / PlaylistCategoryProvider / UserPlaylistProvider /
QRLoginProvider / FullPlaylistProvider / FullMusicProvider`。
统一模型 `model.Song`：

```go
ID, Name, Artist, Album, AlbumID string
Duration int; Size int64; Bitrate int
Source, URL, Ext, Cover, Link string
Extra map[string]string
IsInvalid, IsVIP bool
```

要点：**没有独立 Album/Artist 实体**——专辑 = `Playlist` + `Extra["type"]="album"`，
歌手是分隔字符串；**源 ID 是复合的**（酷狗 hash、QQ songmid、咪咕 `contentId|resourceType|formatType`、
Bilibili `bvid|cid`、5sing `songid|songtype`），`Extra` 必须端到端保留。

### 4.3 独有能力（主项目目前没有）

| 能力 | 位置 | 价值 |
|---|---|---|
| 统一 Provider 接口 | `music-lib/provider` | P0 架构蓝本 |
| 自动换源打分 | `internal/web/music.go:1321` `findBestSwitchSong` + `core.CalcSongSimilarity`（`service.go:895`，名称 0.7+歌手 0.3）、`IsDurationClose`（:873，±10s/15%）、`ValidatePlayable`（:766，Range 探测） | 主项目 `_tryFallbackSource`（仅 netease↔kugou、纯标题歌手匹配）的升级蓝本 |
| 下载元数据内嵌 | `service.go:1589` + 纯 Go ID3v2.3 写入 `embedMP3ID3v23Metadata`（:1193）+ ffmpeg 回退 | 与主项目 Rust downloader 能力互补 |
| 扩展名魔数探测 | `service.go:807/814/836` | 下载落盘格式判定 |
| 并行 Range 流式下载 | `service.go:1324` `NewSourceRangeFetch`（首块 32KB，后续 256KB，16 并发，3 重试） | 在线播放/缓存参考 |
| QR 登录矩阵 | `core/service.go:364-402` | 主项目已有 NT/KG/QQ，可补 Bilibili |
| 随机国内 IP 头 | `music-lib/utils/ip.go`（`X-Forwarded-For`/`X-Real-IP`） | 主项目 netease 已有类似 `system.neteaseRealIp` |

### 4.4 各源协议（**须以实际 `music-lib` 源码复核**）

- **netease**：weapi/eapi/linuxapi；`/api/linux/forward` 搜索、`/weapi/song/enhance/player/url`、
  eapi v1（`lossless/hires/exhigh` 逐档）、`/weapi/v3/song/detail`、`/weapi/v3/playlist/detail`、
  `/weapi/song/lyric`（lv/tv/rv/yv=-1）；VIP 用 `nuser/account/get`。
- **qq**：`c.y.qq.com/soso/fcgi-bin/search_for_qq_cp`、`music.vkey.GetVkey`、musicu.fcg 专辑/歌词
  （`PlayLyricInfo`，QRC hex→DES→zlib）、`i.y.qq.com/qzone-music/.../fcg_ucc_getcdinfo_byids_cp.fcg`；
  QR 含 QQ 与微信（`qq_wx`）。
- **kugou**：`songsearch.kugou.com/song_search_v2`、`/v5/url`、`tracker.kugou.com/v6/priv_url`、
  `wwwapi.kugou.com/play/songinfo`、KRC（base64→去 4 字节→XOR→zlib）；签名
  `md5(salt+sorted(k=v)+data+salt)`；设备注册 AES-CBC + RSA-PKCS1v15。
- **kuwo**：`m.kuwo.cn/newh5/singles/songinfoandlrc`、`mobi.kuwo.cn/mobi.s?...convert_url_with_sign`、
  `nplserver.kuwo.cn/pl.svc`、`newlyric.kuwo.cn/newlyric.lrc`（XOR `yeelion`+zlib+gb18030）。
- **migu**：`pd.musicapp.migu.cn/.../search_all.do`、`.../sub/listenSong.do`（302 Location 为真 URL）、
  `queryAlbumSong`；复合 ID。
- **bilibili**：`x/web-interface/view`、`x/player/playurl`（Hi-Res FLAC/Dolby/DASH）、`x/space/ugc/season`；
  ID `bvid|cid`；QR 登录。
- **qianqian**：`music.91q.com/v1/*`，签名 `md5(sorted(k=v)+Secret)`。
- **soda（汽水）**：`api.qishui.com/luna/*`，CENC AES-CTR 解密（`soda/crypto.go` `DecryptAudio`）。
- **fivesing / jamendo / joox / apple**：小众；Apple 仅试听（预览）。

---

## 5. 交叉对比矩阵

### 5.1 平台覆盖 vs 主项目

| 平台 | 主项目现状 | baka-plugins | go-music-dl | 建议 |
|---|---|---|---|---|
| 网易云 netease | ✅ 75 模块 | ✅ 完整 | ✅ | P1 补强 |
| 酷狗 kugou | ✅ services 完整 | ✅ 完整 | ✅ | P1 补强 |
| QQ qqmusic | ✅ 15 模块 | ✅ 完整 | ✅ | P1 补强 |
| **酷我 kuwo** | ❌ | ✅ 完整 | ✅ | **P2 新增（首选）** |
| **咪咕 migu** | ❌ | ✅ 完整 | ✅ | **P2 新增** |
| Bilibili | ❌ | ✅ 完整 | ✅ | P3 |
| 千千 qianqian | ❌ | ❌ | ✅ | P3 |
| 5sing / Jamendo / JOOX | ❌ | ❌ | ✅ | P3（按需） |
| Apple Music | ❌ | ❌ | ✅（仅试听） | P3（价值低） |
| 汽水 soda/qishui | ❌ | ✅（业务请求全走官方；无损路径依赖第三方签名服务，不采用） | ✅ | P4（仅纯官方路径） |

### 5.2 能力覆盖

| 能力 | 主项目 | baka | go-music-dl | 缺口结论 |
|---|---|---|---|---|
| 搜索（歌/专/歌手/歌单） | ✅ 三家 | ✅ 七家 | ✅ 十二家 | 随新源补齐 |
| 歌曲 URL | ✅ | ✅ | ✅ | 已具备 |
| 歌词（含逐字） | ✅ LRC/YRC/KRC/QRC/TTML | ✅ 含 MRC/QRC 转换 | ✅ 含 QRC/KRC/YRC | 新增源需补 MRC、酷我 `<start,dur>` |
| 歌单详情/导入 | 部分 | ✅ 分页契约完善 | ✅ | P1/P2 补齐 |
| 专辑/歌手 | 部分 | ✅ | ✅ | P2/P3 |
| 评论 | 部分（NT/KG/汽水/QQ，QQ 仅读） | ✅ | ❌ | 参考 baka |
| MV | ❌ | ✅ | ❌ | 可选（baka 参考） |
| 榜单/推荐标签 | 部分 | ✅ | ✅ | P2/P3 |
| 登录/QR | NT/KG/QQ | Cookie 变量 | NT/QQ/QQ_WX/KG/Bili | 新源按需 |
| 自动换源 | 弱（NT↔KG） | ❌ | ✅ 打分+可播性校验 | P1 升级 |
| 下载元数据内嵌 | Rust downloader | ❌ | ✅ ID3v2.3/ffmpeg | 与现有 Rust 对齐 |

### 5.3 加密/协议难度分级（Dart 重实现）

| 难度 | 项 | 依赖 |
|---|---|---|
| 低 | 酷狗 MD5 签名、千千 MD5、酷我 `yeelion` XOR、QQ `zzcSign` | `crypto`、`dart:io` zlib |
| 中 | 网易云 weapi/eapi、咪咕策略解密/MD5、Bilibili WBI/ticket、QQ QRC 3DES | `pointycastle`、`crypto` |
| 高 | 汽水 Spade/CENC、酷狗设备注册 RSA/AES、QQ QMC/BKC、NCM | `pointycastle`、自行实现 DES/CENC 解析 |
| 特殊 | 酷我歌词 **gb18030** 解码 | 需新增依赖或内嵌码表 |

> 主项目已有：netease 的 xeapi（X25519+HKDF+AES-GCM）、QQ TripleDES、酷狗 RSA/AES、KRC 解码。
> 因此**新增酷我/咪咕的加密都在能力范围内**。

---

## 6. 建议的目标架构（纯 Dart）

### 6.1 引入 `OnlineSource` 接口 + 注册表

新建 `app/lib/services/online/`（业务层，符合 `CONTRIBUTING.md` §5.1 目录归属）：

```dart
abstract class OnlineSource {
  String get id;              // 'netease' | 'kugou' | ...（与 Track.source 一致）
  String get displayName;     // 供 i18n 前的默认名
  Set<OnlineCapability> get capabilities; // search/playUrl/lyric/playlist/album/artist/login/comment/mv

  Future<SearchResult<Track>> searchSongs(String kw, {int page, int limit});
  Future<SearchResult<CoverItem>> searchAlbums(...);
  Future<SearchResult<CoverItem>> searchArtists(...);
  Future<SearchResult<CoverItem>> searchPlaylists(...);

  Future<String?> resolvePlayUrl(Track track, {String? quality});
  Future<OnlineLyric?> getLyric(Track track);

  Future<PlaylistDetail> getPlaylist(String id, {int page});
  Future<AlbumDetail> getAlbum(String id);
  Future<ArtistDetail> getArtist(String id);

  Future<LoginSession?> login(...);   // 可选
  Future<void> logout();
}
```

`OnlineSourceRegistry`：`Map<String, OnlineSource>`，提供 `sourceOf(String id)`、`all`、
`aggregatable`（对应 `_aggPlatforms`）。所有现有 switch 改为 `registry.sourceOf(track.source)!`。

### 6.2 `Track` 改造

- 保留现有 `KugouTrackInfo`/`QqMusicTrackInfo` 以零回归；
- **新增通用 `Map<String, dynamic>? extra`**（对齐 go-music-dl `Song.Extra`），新源统一走 `extra`，
  避免每加一个源就改 `Track` 与 `fromJson/toJson`；
- `Track.source` 扩为开放字符串（无中心枚举，维持现状），由 registry 兜底「暂不支持」。

### 6.3 收敛注册点（P0 必做）

| 注册点 | 改为 |
|---|---|
| `playback_notifier_queue.dart:11` `_resolveSource` | `registry.sourceOf(track.source)?.resolvePlayUrl(...)`；`local`/`streaming` 保持特判 |
| `playback_notifier_loading.dart:263` `setQuality` | 同上 |
| `lyrics_provider.dart:40` | `registry.sourceOf(...)?.getLyric(track)`，无则回退本地 |
| `like_controller.dart` | 给 `OnlineSource` 加可选 `LikeCapability` |
| `search_page_view.dart:184` / `search_page_models.dart:60` | tab 与聚合列表由 `registry` 生成 |
| 下载/右键菜单 | 用 `capabilities.contains(download)` 过滤 |
| 登录弹窗 | `OnlineSource.login` + 一个通用 QR 弹窗组件 |

### 6.4 会话 / 缓存 / 歌词

- 会话：沿用 `getRuntime().sessionStore`，key = `source.id`；凭据仍走 vault。
- 响应缓存：沿用 `LruCache`。
- 歌词：新源实现 `OnlineLyric`（`apis/lyric/types.dart` 的 `LyricCandidate`/`LyricMatchResult`），
  接入现有 `lyricCache`/`lyricMatchCache`/`lyricTtmlCache` 与 `pickBestCandidate` 多源回退。
- 音质：沿用 `qualityBitrate`/`qualityLabels`（`track.dart:160/169`），新源声明 `supportedQualities`。

### 6.5 在线音源按需加载与即时卸载（生命周期）

> 背景：平台增多后，若沿用「启动即建全部 facade」会拖慢启动、抬高常驻内存。现状已可见此风险：
> `bootstrap.dart:36` 启动即 `neteaseAuthProvider.init()`；`bootstrap.dart:50` 的
> `likeControllerProvider.sync()` 与 `:76` 的 `ref.listen(qqMusicApiProvider…)` 会实例化各平台 facade；
> `downloadControllerProvider`（`bootstrap.dart:53`）启动即常驻（同类问题见
> `docs/module-on-demand-load-plan.md` §5-②.1）。**新增平台不得沿用该模式。**

与既有规划的关系：`docs/module-on-demand-load-plan.md` 管**原生 FFI 模块**（dlopen 生命周期，
`dart:ffi` 无法 unload）；本节管**纯 Dart 在线音源对象**（facade / HTTP client / 缓存 / 会话）。
两者原则一致——**注册表 + 引用计数 + 空闲释放 + 任务互斥**——可共用同一套 `ResourceRegistry` 抽象。

设计（`OnlineSourceRegistry` 即生命周期入口）：

1. **工厂而非实例**：注册表存 `OnlineSource Function()`，首次使用才构造
   （打开该平台搜索 tab、播放该源曲目、取该源歌词时）。
2. **租约 + 引用计数**：`acquire(sourceId, reason)` / `release(sourceId, reason)`；
   `reason ∈ {searchTab, currentTrack, lyric, download, fallback, likeSync}`；计数 > 0 期间不可卸载。
3. **空闲 TTL 卸载**：计数归零后进入 idle，超时（如 5 分钟）且无进行中请求 → 卸载：
   关闭 `HttpClient`（`close(force: true)`）、取消定时器、清空该源缓存（`LruCache`）、
   清运行时状态（**不删 vault 会话**，会话按需重新加载）。
4. **任务互斥**：有进行中请求 / 下载 / 播放时不释放（对齐 `module-on-demand-load-plan.md` §5-②.3）。
5. **启动只做「轻量恢复」**：不主动构造 facade；登录态/红心改为「首次进入该源时初始化」，
   或只恢复必要最小状态，避免 `bootstrap` 全量实例化。
6. **聚合搜索按需**：`all` 聚合时对参与源逐个 `acquire`，完成后可 `release`；
   切 tab 只 `acquire` 选中源。
7. **释放后误用保护**：facade 加 `_released` 标志，调用抛 `StateError`，可重新 `acquire`。
8. **缓存预算**：每源独立上限（沿用 `LruCache` TTL/max），卸载即清；
   播放内容缓存（`SongCache`）按磁盘预算独立管理，**不随源卸载**。

Dart 机制说明（避免误用）：

- `deferred as` 代码分割在 **Flutter 桌面/原生不可靠**（非桌面代码分割机制），**不作为方案**；
  「按需」应落在**运行时对象生命周期**（懒构造 + 释放）上。
- Riverpod：`Provider` 默认懒构造；per-source 状态用 `autoDispose`，但**播放/歌词期间必须
  `keepAlive`**（由租约计数控制），否则会在播放中被释放。
- HTTP：`dart:io HttpClient` 支持 `close(force: true)` 终止连接；自建请求层需暴露取消能力。

验收：启动不构造任何未使用源；切到某源 tab 才见首次请求；卸载后 RSS 回落（度量）。

---

## 7. 分阶段落地清单

### P0 架构重构（无新平台，行为零回归）
- [ ] `services/online/online_source.dart`：接口 + `capabilities`。
- [ ] `services/online/online_source_registry.dart`：注册表 + **按需加载/即时卸载**（§6.5）：
      工厂懒构造、`acquire/release` 租约、空闲 TTL 卸载、任务互斥、释放后误用保护。
- [ ] 把 netease/kugou/qqmusic 包一层适配器实现 `OnlineSource`。
- [ ] 替换 §6.3 的 7 类 switch。
- [ ] `Track` 增 `extra`（含 `fromJson/toJson`）。
- [ ] 解除 `bootstrap.dart` 全量实例化（`neteaseAuthProvider.init` / `likeController.sync` /
      `qqMusicApiProvider` 监听 / `downloadControllerProvider`）→ 改为按需首次初始化（§6.5）。
- [ ] 测试：沿用 `app/test/` 现有注入式单测（如 `qqmusic_search_failure_test.dart`、`search_source_state_test.dart`），
      确保重构后全绿；`dart analyze lib` 0 issue。

### P1 现有三源补强（参考两个项目）
- [x] QQ：**搜索已重写为签名桌面协议**（`zzcSign` + `musics.fcg` `DoSearchForQQMusicDesktop`，
      `ct=19` 全量 size），单曲/歌手/专辑/歌单四类统一（`search_type` 0/1/2/3）；**移动搜索已移除**。
      **评论已接入**（`music.globalComment.CommentRead` `GetHotCommentList`/`GetNewCommentList`，
      读取需登录；`QqMusicApi.songComments` + 评论弹窗 hot/new 两 Tab，仅读不发）。
      仍待补：专辑分页、榜单增强（baka `qq.js:179/869`）。
- [ ] 酷狗：全局收藏歌单 `get_other_list_file_nofilt`、酷狗码解析、分享歌单（baka `kg.js:1356/1682/1625`）。
- [ ] 网易云：eapi 歌词、YRC→QRC、批量音质、`trackIds` 本地缓存（baka `wy.js:880/553/317/430`）。
- [ ] 自动换源升级：多候选源 + 相似度打分 + 时长校验 + Range 可播性探测（go-music-dl `music.go:1321`、`service.go:895/873/766`）。

### P2 新增酷我 + 咪咕（首选）
- [ ] `lib/apis/kuwo/`（core 签名 + modules）与 `lib/services/kuwo/`（门面）：搜索/URL/歌词/歌单/专辑/歌手/MV/榜单/评论。
      - 参考 baka `kw.js`（`buildParams` :656、歌词 :437）与 go-music-dl `music-lib/kuwo`。
      - **注意**：歌词 gb18030 解码需引依赖或内嵌码表（新增依赖须 §9 登记）。
- [ ] `lib/apis/migu/` + `lib/services/migu/`：搜索/URL 策略解密/歌词 MRC(TEA)/专辑/歌手/歌单。
      - 参考 baka `mg.js`（签名 :463、策略解密 :89、TEA :589）。
- [ ] 各自注册进 `OnlineSourceRegistry`，加登录（如需要）、加 i18n key。

### P3 扩展源（按需）
- [ ] Bilibili（WBI、DASH、收藏夹、字幕歌词；参考 baka `bilibili.js`、go-music-dl `music-lib/bilibili`）。
- [ ] 千千（`music.91q.com`，签名简单）。
- [ ] 5sing / Jamendo / JOOX（小众；go-music-dl `music-lib/*`）。
- [ ] Apple（仅试听，价值低，可跳过）。

### P4 汽水（仅纯官方路径；签名服务不接入）

**核实结果**（逐请求追踪 `plugins/qishui.js`，2026-09-14）：

业务/内容请求**全部指向官方域名**：

| 用途 | 目标 | 出处 |
|---|---|---|
| Android 搜索 / `track_v2` | `https://api.qishui.com/luna` | `qishui.js:35/688/621` |
| PC 专辑/歌手/歌单/发现/榜单/评论 | `https://api.qishui.com/luna/pc` | `qishui.js:33/702/711` |
| 按 vid 取流 | `https://api.qishui.com/luna/player` | `qishui.js:2114` |
| SEO 取流兜底 | `https://beta-luna.douyin.com/luna/h5/seo_track` | `qishui.js:1489` |
| 分享页 | `https://music.douyin.com/qishui/share/*` | `qishui.js:23/186` |
| 图片 | `https://p3-luna.douyinpic.com/img/` | `qishui.js:22` |
| 榜单兜底 | `https://api5-lf.qishui.com/luna/charts/` | `qishui.js:2431` |
| 内容查询 | `https://api-vehicle.volcengine.com/v2/{custom/contents,search/type}`（字节火山引擎，无 cookie；归属核查见下） | `qishui.js:1862/1913` |

**域名归属核查（2026-09-14，实测）**：

- **`api-vehicle.volcengine.com` = 字节火山引擎（ByteDance 官方云），但非汽水 App 官方 API**：
  TLS 证书 `CN=*.volcengine.com`（DigiCert/RapidSSL 签发）；响应头 `Server: Tengine` +
  `X-Tt-Logid` / `x-tt-trace-id` / `EagleId`（字节 TT 基础设施特征）；`volcengine.com` 官网即
  「火山引擎 / 字节跳动」；接口无需凭据即返回 `"source":"qishui","from_app":"qishui"` 内容。
  即它是**字节官方的内容聚合 / 车机接口**（`/v2/search/type`、`/v2/custom/contents`），
  会把**搜索词与歌曲 ID** 发往该云服务（**不含账号凭据**）。Mineradio `qishui-api.js:18-19`
  与 baka `qishui.js:1862/1913` 均使用它；music-lib `soda/` **未使用**。
- **`api.music.qishui.vsaa.cn` = 真第三方（个人），必须排除**：
  `vsaa.cn` WHOIS 注册人为**个人**（`Registrant: 程亮`，邮箱 `603212202@qq.com`，
  注册商「成都垦派科技有限公司」，**注册时间 2025-10-17**，不足一年）；HTTP 80 实测 502。
  它**能读到 `sessionid`**。Mineradio 自检脚本已明令禁止该域名
  （`scripts/quick-check.js:1668`：命中 `vsaa.cn` 即判失败）。

**唯一非官方域名**：`http://api.music.qishui.vsaa.cn/qm/api.php`（第三方 X-Headers 签名服务，`qishui.js:37`），
**仅在 Android `track_v2`（无损 / 逐字歌词路径）调用**（`signQishuiAndroidRequest`，`qishui.js:451`）。
它收到 `{ url, body(base64), cookie:"sessionid=...", ua:"", send:false }`，返回
`x-khronos/x-argus/x-gorgon/x-helios/x-ladon/x-ss-stub/x-medusa`。
- `send:false` = **只代算请求头，不代发业务请求**；真正的 `track_v2` 仍由客户端打到官方 `api.qishui.com`。
- 但它**能读到 sessionid**：默认是插件内置公共值 `3e60f931253128d953e15144ba7105f1`（`qishui.js:61`），
  用户变量可覆盖为个人账号（`getQishuiSessionId`，`qishui.js:390`）。

**决策（受 §8.1 零第三方硬约束约束）：只走纯官方路径**，签名服务 `vsaa.cn` **不接入**：

- [ ] **官方路径**：PC API（`/luna/pc`）+ SEO（`beta-luna.douyin.com`）取流，
      **完全不调用 `vsaa.cn`**；代价：暂不提供 Android `track_v2` 的**无损/空间音频**；
      **逐字歌词不受影响**（实测 SEO `seo_track.lyric.type=krc`，可直接接入现有 KRC 逐字管线）。
- [ ] **禁止**使用 `vsaa.cn` 签名服务（无论用公共默认还是个人 sessionid）——它是**个人第三方**，
      违反「任何数据不得经过第三方」。
- [ ] **不使用 `api-vehicle.volcengine.com`**（字节火山引擎内容接口）：虽属字节官方云，但**非汽水
      官方客户端域名**，且会把搜索词 / 歌曲 ID 出站；主项目已有纯 `qishui.com` 官方搜索 / 取流路径
      （music-lib `soda/` 全程未用它），故**不纳入白名单**。
- [ ] 实现 `lib/apis/soda/` + `lib/services/soda/`：搜索、PC/SEO 取流、`play_auth`（Spade/CENC，
      `qishui.js:291`）、歌词（KRC→QRC，`qishui.js:1082`）、歌单、榜单、评论；
      参考 go-music-dl `music-lib/soda`（含 CENC `DecryptAudio`）。
- [x] 若要**无损/空间/母带**：**无需本地签名**——PC `seo_track` 的 `track_player.video_model`
      （JSON 串）`video_list[]` 已含多档直链；**带会员 cookie 即出现 `lossless`/`spatial`/`hi_res`**
      （免签名、免 `x-gorgon`）。仅在需要 Android `track_v2`/受保护接口（PC `search/track`、
      `users/{id}`、`media-player`）时才需要签名；本项目搜索走 Android、播放走 SEO，故不依赖签名。

**官方零第三方路径能力实测（2026-09-14，免凭据单次探测）**：

| 能力 | 端点 | 免登录 | 免签名 | 结论 |
|---|---|---|---|---|
| 单曲元数据/封面/时长 | SEO `beta-luna.douyin.com/luna/h5/seo_track` | ✅ | ✅ | ✅ 可用 |
| **逐字歌词（KRC）** | 同上 `lyric`（`type=krc`；`[行start,dur]<字start,dur,?>字…`） | ✅ | ✅ | ✅ 可用（接入现有 KRC→逐字管线） |
| **免费曲完整播放** | 同上 `track_player.url_player_info` → `PlayInfoList`（明文 m4a，无 `PlayAuth`） | ✅ | ✅ | ✅ 可用（`medium`/`higher`/`highest`） |
| VIP 曲播放 | 同上（`preview.duration < duration` 时返回 30/60s 试听流） | ✅ | ✅ | ⚠️ 仅试听；完整需登录 + 会员 |
| 无损/空间/母带 | PC `seo_track` → `track_player.video_model.video_list`（**会员 cookie** 即出 `lossless`/`spatial`/`hi_res`） | ✅（免登录仅 medium/higher/highest） | ✅ | ✅ 可用（会员 cookie 解锁高解析，免签名） |
| 专辑详情 + 曲目 | PC `/luna/pc/albums/{id}` | ✅ | ✅ | ✅ 可用 |
| 歌手作品 | PC `/luna/pc/artists/{id}/{albums,tracks}` | ✅ | ✅ | ✅ 可用 |
| 歌单详情 + 曲目 | PC `/luna/pc/playlist/detail` | ✅ | ✅ | ✅ 可用 |
| 榜单 | PC `/luna/pc/charts/{id}`、`api5-lf.qishui.com/luna/charts/{id}` | ✅ | ✅ | ✅ 可用 |
| 评论 | PC `/luna/pc/comments`（读 `group_id`+`cursor`+`count`+`group_type`(0最新/1热门)+`image_strategy=2`；发 `/luna/pc/comments/create`） | ✅ 读取免登录 | ✅ | ✅ 已接入（`apis/soda/modules/comment.dart`；发布需登录 cookie） |
| 搜索 | PC `/luna/pc/search/track` | ❌ 需登录 | ✅ | ⚠️ 未登录官方搜索为空（Mineradio 用被排除的 volcengine 兜底） |
| 用户歌单 / 红心 | PC `/luna/pc/me/*` | ❌ 需登录 | ✅ | ⚠️ 需登录 |
| 扫码登录 | Passport Web QR（`api.qishui.com/passport/*` + `bff-pc.qishui.com/scan_login` + `auth/verify.zijieapi.com`） | — | 需 ByteDance 安全 SDK（`bdms.js`） | ⚠️ 复杂（Mineradio 已移植） |
| 下载 | URL + Spade CEK（`PlayAuth`）+ CENC AES-CTR 解密 | — | ✅ 纯算法 | ✅ 已实现（`decrypt.rs`，接入下载器） |

> 官方质量档位（`label_info.quality_map`）：`medium`(≈65k) / `higher`(≈130k) / `highest`(≈258k) /
> `lossless` / `spatial` / `hi_res`；免费曲可播 `medium~highest`，`lossless`/`spatial`/`hi_res` 需 VIP。
> 关键实测：非 VIP 曲的 SEO `PlayInfoList` 返回**全曲时长**（如 `dur=205s` 返回 ≈205s 流）；
> VIP 曲返回 30/60s 试听——**判据是 `label_info.only_vip_playable`，而非 `preview` 字段**。

**完整登录方案（本次确认，2026-09-14）：纯 Dart HTTP 复刻（实测免 `a_bogus`），不引 WebView / JS 运行时。**

> 决策：汽水**完整登录**（扫码 + 会话 + 短信 MFA）**纯 Dart HTTP 复刻**——不引入 WebView、
> 不内置 `bdms.js`/`sdk-glue.js`、不起 JS 运行时（守住 §2.2 零大运行时）。
> **主参考改为 go-music-dl `music-lib/soda/login.go`（纯 Go `net/http`，无浏览器、无 `a_bogus`）**；
> Mineradio `qishui-auth-v6.js` 仅作**浏览器路径的对照**，其 Chromium 方案**不需要**。

**实测（2026-09-14，按 `music-lib/soda/login.go` 参数复现）**：

- `GET /passport/web/get_qrcode/` → `error_code:0` + `token` + `qrcode_index_url` + base64 二维码 +
  `passport_csrf_token` cookie；
- `POST /passport/web/check_qrconnect/` → `error_code:0`、`status:"new"`、`message:"success"`；
- **两步均无需 `a_bogus` / `msToken` / `bd-ticket-guard` / JS SDK / 浏览器**（仅 UA + passport 公共参数
  + `get_qrcode` 下发的 csrf cookie）。
- 结论：`a_bogus` **非登录必需**（保留为「若日后接口收紧」的兜底）；登录主链路可 100% 纯 Dart HTTP。

登录端点与实现要点（主参考 `music-lib/soda/login.go`）：

| 步骤 | 请求 | 关键参数 / 头 | 参考 |
|---|---|---|---|
| 取二维码 | `GET api.qishui.com/passport/web/get_qrcode/` | passport 公共参数 + `next/need_logo/need_short_url/is_frontier`；下发 `passport_csrf_token` | `soda/login.go:130/908` |
| 轮询扫码 | `POST /passport/web/check_qrconnect/` | `token` + `is_new_login/next`；带 csrf cookie；2046 时解析 `encrypt_uid`/`verify_params` | `:312/921` |
| 二维码内容 | `bff-pc.qishui.com/light/invoke/scan_login?token=…&os=Windows&computer_name=…` | 无 | `:1000` |
| 短信发码 | `POST /passport/web/send_code/` | `encrypt_uid` + `std_verify_way=mobile_sms_verify` + `type=3737` 等 | `:524` |
| 短信校验 | `POST /passport/web/validate_code/` | 同上 + `code` → `data.ticket` | `:681` |
| 上行短信 | `POST /passport/upsms/verify/` | `std_verify_way=mobile_up_sms_verify` | `:607` |
| 二次验证(2046) | 回填服务端下发的 `verify_params` 后再轮询 `check_qrconnect` | 服务端下发 `encrypt_uid`/`verify_params`，客户端原样回填 | `:458` |

需在 `lib/apis/soda/core/` 复刻（**纯 Dart，无新依赖**）：

- passport 公共参数（必需）：`passport_jssdk_version=2.4.13`、`aid=386088`、
  `device_id`/`install_id`/`did`/`iid`、`is_from_ttaccountsdk=1`、`account_sdk_source=web`、
  `p_js_v/p_js_t/p_zt/p_ver/p_bd` 等（`login.go:948-998`）。
- `msToken`（可选）：本地随机 `base64url(88B)+==`；**实测非必需**。
- `account_sdk_source_info`（可选）：指纹 JSON 的 XOR5-hex（`security_host.html:76`）；**实测非必需**。
- `a_bogus`（可选兜底）：ByteDance web 签名；**实测 QR 两步非必需**，留待接口收紧时再评估。
- `x-ss-stub`（可选）：`md5(body).toUpperCase()`。
- `bd-ticket-guard-*`（可选）：`login.go:780-784` 的静态头；**实测非必需**。

**风险与边界（必须记录）**：

- **MFA 短信可纯 Dart**（`send_code`/`validate_code`/`upsms/verify`，服务端下发 `verify_params` 回填）；
  **滑块 / 拼图 / 人脸不可**（见下「MFA 判定」）。
- 接口收紧时可能重新要求 `a_bogus` / `account_sdk_source_info` → 保留兜底实现与降级。
- **不复制** Mineradio `bdms.js` / `sdk-glue.js` 任何代码；仅作协议参考。
- 落地：`lib/apis/soda/core/{passport_params,ms_token,fingerprint,sign}.dart` + `modules/login_qr.dart`
  + `lib/services/soda/soda_auth.dart`；会话 cookie 入 vault（平台键 `soda`）。

**自研边界与 MFA 判定（2026-09-14）**：

- **music-lib 范式（主参考，已实测）**：`music-lib/soda/login.go` 用**纯 Go `net/http`**完成
  二维码创建/轮询 + 短信 MFA（`send_code`/`validate_code`/`upsms`），**全程无 `a_bogus`、无浏览器**；
  主项目已按其参数**实测复现** `get_qrcode` / `check_qrconnect` 成功。→ 汽水完整登录可**纯 Dart HTTP**。
- **NetEase 范式（同类先例）**：主项目 `apis/netease/core/crypto.dart` 已用**纯 Dart**
  实现 weapi / eapi / linuxapi / **xeapi（X25519+HKDF+AES-GCM）**，以及二维码登录
  （`unikey` + 轮询 `client/login`，`modules/login_qr_*.dart`）——**零 WebView、零插件**。
  说明「复杂签名纯 Dart」在本项目已是既有能力，作为 `a_bogus` 兜底实现的能力背书。
- **Mineradio 的登录机制（明确不复用）**：它在 **Electron 的 Chromium 渲染进程**里加载本地壳页
  + 官方 `sdk-glue.js`/`bdms.js`（`qishui-auth-v6.js:250-298`），请求经 `window.__qishuiRequest`
  （浏览器内 XHR）发出，由官方 JS 现场注入 `a_bogus`/`msToken`；MFA 再加载官方
  `ucWebSecondVerify`/`rmc-captcha`。即**依赖完整浏览器 + 官方 JS**——正是 §2.2 要避免的大运行时，
  **不移植**（这也解释了为何它「能完整登录」：它把浏览器一起搬进来了）。
- **MFA 可行性判定**：
  - **短信分支（可纯 Dart）**：`api.qishui.com/passport/web/send_code/` → `validate_code/`
    （或上行短信 `upsms/verify/`）→ 回填 `verify_params` 再轮询 `check_qrconnect`；
    流程与参数见 `music-lib/soda/login.go:524-758`。
    （Mineradio 浏览器版走 `verify.zijieapi.com/notify/sms/web/*`，是同一短信能力的另一实现，**不需要**。）
  - **滑块 / 拼图**（`rmc-captcha`，`lf-cdn-tos.bytescm.com/.../rmc-captcha/@latest/captcha.js`，810KB）：
    **AES-GCM 加密拖拽轨迹 + `__vc_detect__` 设备 / 自动化检测**，服务端只认其 `verify_data`；
    「自研」等于逆向风控 → **判定不做**（对抗性质、易失效、且非算法而是反机器人机制）。
  - **人脸 / 实名**：官方组件 → **放弃**。
- **降级策略**：纯 Dart 覆盖「常规登录 + 短信 MFA」；持久化 `deviceId`/`installId`/`verifyPortraitId`/
  `msToken` 降低 MFA 触发率；真触发滑块 / 人脸时，提示「请在官方汽水 App 完成安全验证后重试」，
  **不静默失败**。

**登录请求流（抓包还原，2026-09-14；来源 `music-lib/soda/login.go` + `login_test.go`）**：

1. **取二维码** `GET /passport/web/get_qrcode/?<normal query>`（UA + Accept）→
   `{data:{token,qrcode(base64),qrcode_index_url,expire_time}}` + `Set-Cookie: passport_csrf_token`；
   二维码内容取 `qrcode_index_url`（`bff-pc.qishui.com/ucenter_web/app/sdk-next?…&token=…`）。
2. **轮询** `POST /passport/web/check_qrconnect/?<normal query>`（带 csrf cookie；body
   `need_logo/need_short_url/is_frontier/token/is_new_login/next`）→ 状态 `new→scanned→confirmed`，
   成功下发 `sessionid/sessionid_ss/sid_tt/sid_guard`；`error_code=7` 限流冷却 60s。
3. **2046 MFA**（真实抓包）：
   ```json
   {"data":{"account_flow":"verify","encrypt_uid":"fXk7…","error_code":2046,
     "biz_params":{"passport_mfa_retry_tag":"1","std_verify_flow_id":"…login",
       "std_verify_scene":"account_login","std_verify_template":"ato",
       "std_verify_token":"…_lq","std_verify_type":"MFA","std_verify_way":""},
     "verify_ways":[
       {"act_type":"22","mobile":"159******49","verify_way":"mobile_sms_verify"},
       {"channel_mobile":"9515211003","mobile":"159******49","sms_content":"YZ","verify_way":"mobile_up_sms_verify"}]},
    "message":"error"}
   ```
   + `Set-Cookie: passport_mfa_token`。**该抓包只给短信方式，无滑块**。
4. **短信**：`send_code`（`std_verify_way=mobile_sms_verify`）→ `validate_code`
   （`code` = 数字 ASCII 的 hex，如 `661701→363631373031`）→ 回填 `biz_params` 再轮询；
   或上行短信 `upsms/verify`（把 `sms_content` 发到 `channel_mobile`）。
   MFA 接口用 **lite query**（`passport_jssdk_version=5.1.2`、`passport_jssdk_type=lite`、
   `new_authn_sdk_version=1.0.0.404-web`）。

> 要点：MFA 的 `encrypt_uid`/`biz_params`/`verify_ways` **全部服务端下发、客户端原样回填**；
> 是否弹滑块取决于账号风控（本抓包走短信）。

### P5 本地签名与下载增强（后期 R&D，彻底去第三方）

> 目标：把「官方直连」从「够用」推进到「完整」——补齐需要**本地签名**的能力，以及下载端的
> **解密 / 标签内嵌**，从而在不依赖任何第三方的前提下拿到官方全量能力。
> 前提：仍受 §8.1 硬约束——出站域名只含官方域名；一律自研，不引第三方运行时/私有接口。

**A. 本地签名（纯 Dart，`lib/apis/<platform>/core/`）**

| 平台 | 待实现的签名 | 难度 | 参考 |
|---|---|---|---|
| Bilibili | WBI（mixin key + `w_rid`）、ticket HMAC-SHA256 | 低（算法明确） | baka `bilibili.js:209/223` |
| 千千 qianqian | `md5(sorted(k=v) + Secret)` | 低 | `music-lib/qianqian` |
| 酷我 kuwo | `yeelion` XOR + base64、官方 `convert_url_with_sign` | 低 | baka `kw.js:656` |
| 咪咕 migu | MD5 签名、策略响应解密、MRC TEA | 中 | baka `mg.js:463/89/589` |
| QQ | 搜索结果签名已落地（`core/sign.dart` `qmZzcSign` + `musics.fcg`，四类）；`song_url`/GetVkey 已具备 | — | 主项目 `apis/qqmusic/core/sign.dart` |
| 汽水 soda | **登录**：纯 Dart HTTP 即可（passport 公共参数 + csrf cookie；**实测免 `a_bogus`**，见 §7-P4）；**短信 MFA**：`send_code`/`validate_code`/`upsms` 纯 Dart；`a_bogus`/`account_sdk_source_info`/`x-ss-stub` 作可选兜底；`x-gorgon/x-argus`（Android `track_v2`）需逆向 ByteDance 风控 | 中（登录/短信）；高（`track_v2`） | `music-lib/soda/login.go`（主）、Mineradio `qishui-auth-v6.js`（对照） |
| 网易云/酷狗 | 已具备（weapi/eapi/xeapi、酷狗签名/KRC） | — | 主项目现有 |

**B. 下载端增强（与现有 Rust `archoera-downloader` / C++ scraper 协同）**

- [x] **QQMusic / 汽水下载接入**（2026-09-14）：Rust `SourcePlatform` 增加 `Qqmusic`/`Soda`，
      二者无自研解析 → 解析阶段返回可重试错误，由 **Dart 播放管线回退**（§12.1
      `resolvePlaySource` + `retry_with_url`）注入 URL；Dart 回退门控/预解析 headers 扩展
      （QQ 带 Cookie/UA/Referer、汽水带 UA，VIP `#auth=` 跳过）；下载 UI 放开 QQ/汽水入口。
      Rust 单测 + Dart 请求单测 + `cargo build --release` 通过。
- [x] **加密容器解密（原生 Rust，2026-09-14）**：`app/core/downloader/src/decrypt.rs` 自研重写
      网易 **NCM**（含 `ncm_metadata` 标题/歌手/专辑/封面提取）、QQ **QMC**（静态掩码 58 + 首块掩码
      探测）、汽水 **CENC/AES-CTR**（`senc` 逐样本 IV + Spade `PlayAuth` 派生 key，`enca`→`mp4a`）；
      通用入口 `decrypt_container`（按魔数/扩展名分派），**已接入下载器**（下载落盘后自动识别解密
      → 扩展名归正 → 再写标签；CENC 经预解析 URL 片段 `#auth=` 携带 PlayAuth）。参考 `music-lib`
      （AGPL-3.0）Go 实现，**未复制**无许可证项目代码。单测：NCM/QMC 往返 + NCM 元数据 + Spade key +
      合成 MP4 全链路往返 + 分派。**QMC 完整流密码（2026-09-14 续）**：`src/qmc.rs` 另实现
      `QTag`/legacy/`musicex` footer 解析、`deriveKey`/`deriveKeyV2`（TEA-CBC）、`Static`/`Map`/`RC4`
      密码（参考 MIT 的 `lantianhcgp/unlock-music` + `pushbox/qmc2`，随附其测试向量对拍全绿）。
      **注意**：新版 PC 缓存 **`musicex` 文件不含密钥**——需 QQ 客户端本地 MMKV key 库按
      `MediaFileName` 查得；本项目只做算法、不内置密钥。**待补**：客户端 MMKV key 导入、NCM 扫描入库链路。
- [ ] **扩展名魔数探测**（wma/flac/ID3/ogg/ftyp…）——参考 go-music-dl `service.go:807/814/836`。
- [ ] **Range 并行下载**（首块 32KB，后续 256KB，多并发 + 重试）——参考 `service.go:1324`。
- [ ] **标签内嵌**：ID3v2.3 / Xiph / MP4 / RIFF——主项目已有 C++ TagLib 刮削，优先复用；
      纯 Dart/Go 参考 go-music-dl `service.go:1589`。

**C. 约束与验收**

- 一律**自研/自实现**，参考来源逐项登记 `THIRD-PARTY-LICENSES.md`（§9）。
- 签名/风控失败时**静默降级**到现有可用路径，不影响播放（§10.4 容错语义）。
- 出站域名断言：新增平台只允许官方域名（可在 `app/test/` 注入式 transport 中断言）。
- 优先级：先做「算法明确」的（Bilibili WBI、千千、酷我、咪咕），
  ByteDance `x-gorgon` 等高风险项**仅在必要时投入**。

### 实施状态与起步计划（2026-09-14）

**已实测（本机，免凭据）**：

- **QQ**：`zzcSign` + `POST u.y.qq.com/cgi-bin/musics.fcg?sign=…`（`ct=19`）→ `code:0`、
  `meta.sum:999`、`file` 含 `size_hires` / `size_new[14]` / `size_dolby` / `size_dts` /
  `hires_sample` / `hires_bitdepth`。算法索引越界（`hash[40]`）按 JS `join` 语义**丢弃为空**。
- **汽水**：`get_qrcode` / `check_qrconnect` 免 `a_bogus`（§7-P4）；SEO `seo_track` 返回
  KRC 逐字歌词 + 免费曲全曲流；PC `albums` / `playlist/detail` / `charts` 免登录可用。

**起步计划（两刀，各自可独立验证；不引新依赖、不碰原生层）**：

- **刀 1 — QQ P1（✅ 已完成，2026-09-14）**：
  - [x] `core/sign.dart`：`qmZzcSign`（SHA1 大写 + 索引取字 XOR 混淆 + 去填充 base64；越界下标按
        JS `join` 语义丢弃）。
  - [x] `modules/search.dart`：**整体重写为签名桌面协议**——`musics.fcg` + `?sign=`、
        `DoSearchForQQMusicDesktop`、`ct=19`／`cv=2151`／`searchid`／`remoteplace=txt.newclient.top`；
        单曲/歌手/专辑/歌单（`search_type` 0/1/2/3）统一，响应分列
        `body.{song,singer,album,songlist}.list`。**移动端 `DoSearchForQQMusicMobile` 已删除**
        （原分页上限、`item_*` 字段、hires 缺失等脆弱点一并去除）。
  - [x] `services/qqmusic/qqmusic_api.dart`：四类搜索改走桌面协议（type 0/1/2/3，原移动 8/9/2 修正）；
        歌手单页收敛 30；错误归一（风控 `2001`/`meta.is_filter<0` 不重试、瞬时退避重试、
        已登录 comm 注入 `uin/qq/authst/tmeLoginType=2`）。
  - [x] 验证：`dart analyze lib` 0 issue；`qqmusic_search_failure_test.dart` /
        `qqmusic_session_comm_test.dart` 全绿；`qqmusic_direct_test.dart` 真实联网 8/8。
- **刀 2 — 汽水（新建 `lib/apis/soda/` + `lib/services/soda/`）**：
  - [x] 免登录 **API 层**（`lib/apis/soda/`）：Android 搜索（`/luna/search/{track,album,playlist}`）、
        SEO `seo_track`（元数据 + KRC 逐字歌词 + `url_player_info`）、`play_info`（官方 VOD
        `vod-luna.douyin.com` 取流）、PC 专辑 `/luna/pc/albums/{id}`、PC 歌单 `/luna/pc/playlist/detail`；
        **官方域名硬校验**（`core/request.dart`，非白名单拒绝发起）。实测免登录可用；
        `soda_official_only_test.dart` + `soda_direct_test.dart`（真实联网）通过。
  - [x] 免登录 **service 门面 + UI 接入**：`lib/services/soda/soda_api.dart`（搜索/取流/歌词/
        歌单/专辑归一为 `Track`/`CoverItem`）；`sodaApiProvider`；搜索页新增「汽水」平台
        （`l10n.platformSoda`）、四类 fetch、专辑/歌单详情弹窗；播放源解析（`play_source_resolver`
        / `setQuality` / 搜索页 `_playTrack`）与歌词（`apis/lyric/soda.dart`，KRC）接入；
        汽水红心暂返回不支持。
  - [x] **登录**（纯 Dart HTTP，无 `a_bogus`/WebView）：`apis/soda/core/passport.dart`（公共参数 +
        固定字段顺序编码 + MFA 回填收集）、`apis/soda/modules/login_qr.dart`（`get_qrcode` /
        `check_qrconnect` / `send_code` / `validate_code` / `upsms`）、`services/soda/soda_auth.dart`
        （编排 + 会话入 vault 键 `soda`）、`widgets/dialogs/soda_login_dialog.dart`（扫码 + 短信 MFA UI）。
        实测 `get_qrcode` / `check_qrconnect` 免签名可用；`soda_login_test.dart` + `soda_login_direct_test.dart` 通过。
  - [ ] 待补：歌手 / 榜单端点（PC `/luna/pc/artists`·`charts` 待定位）；VIP 曲 CENC 解密（P5）。
  - [ ] 验证：`dart analyze lib` + 注入式 transport 断言出站域名只含官方。

**待真实账号验证（新会话需注意）**：汽水扫码后的 2046 短信 MFA 与会话下发；QQ 登录态音质 / 下载。

---

## 8. 合规与红线（必须遵守）

| 约束 | 出处 | 对移植的影响 |
|---|---|---|
| 禁止非 FFI 大运行时（Node/Python/JVM） | `CONTRIBUTING.md` §2.2、戒律 #11 | baka-plugins **不可运行**，只能参考 |
| 纯 Dart 平台协议层 | 戒律 #2 | 所有协议必须纯 Dart 重实现，不起子进程、不引 Go/JS |
| 高度不建议第三方「预制菜」整包引入 | §2.2、§9 | 不可整包复制；须「参考移植 + 来源可溯 + 逐项登记」 |
| 新增语言栈须走 §13 决策修订 | §2.2、戒律 #11 | 不得为 go-music-dl 引入 Go 业务层（Subsonic 属既有例外） |
| 许可白名单 + 登记义务 | §9 | `go-music-dl`/`music-lib`（AGPL-3.0）可在 `THIRD-PARTY-LICENSES.md` 登记为参考；`baka-plugins` **无许可**，只能参考协议事实，不得复制代码/表达 |
| **零第三方数据流（硬约束，本次确认）** | 本次确认 | 任何聚合网关 / 签名服务 / 代理不得进入请求链路；只与官方域名通信（见 §8.1） |
| 用户数据仅存本地、禁止向第三方上传 | §2.1、§10 | 汽水签名服务 `vsaa.cn` **不接入**；只走纯官方路径，个人 sessionid 不出本机（§7-P4） |
| 禁止遥测/埋点、禁强制联网验证 | §2.1 | 不得引入插件分发/订阅/更新回调 |
| 禁付费解锁/会员墙 | §2.1 | 只做正常登录态音质，不做 VIP 破解/解锁逻辑 |

> 具体动作：新建/更新对应模块 `THIRD-PARTY-LICENSES.md`，逐项列明
> `baka-plugins`（来源、无许可证、涉及参考的文件范围）、`go-music-dl` + `music-lib`（AGPL-3.0、commit
> `v1.1.1-0.20260828151741-02402db9ef9d`）；PR 说明中写清「参考了哪些文件、重实现了什么」。

### 8.1 零第三方硬约束：逐平台官方路径映射

> **硬约束（本次确认）**：**任何数据都不得经过官方平台以外的第三方**——解析、取流、歌词、歌单、
> 登录、评论只与官方域名通信；任何聚合网关 / 签名服务 / 代理**都不得进入请求链路**。
> 「数据」包括账号 cookie/token、歌曲 id、搜索词、播放请求、歌词请求等一切出站内容。

现状与缺口：

- **已完整（官方直连）**：网易云（`lib/apis/netease/` + `lib/services/netease/`）、
  酷狗（`lib/services/kugou/`）。
- **已有官方直连、待补强**：QQ（`lib/apis/qqmusic/`）。
- **缺失解析能力、需新增（全部走官方）**：酷我、咪咕、Bilibili、千千、5sing、Jamendo、JOOX、
  Apple、汽水。

| 平台 | 官方取流路径（建议） | 参考来源 | 禁止的第三方 |
|---|---|---|---|
| 酷我 kuwo | 官方 `m.kuwo.cn` / `mobi.kuwo.cn/mobi.s?type=convert_url_with_sign`（`br=128kmp3/320kmp3/2000kflac`） | baka `kw.js`、`music-lib/kuwo` | `music.nxinxz.com` 等网关 |
| 咪咕 migu | 官方 `app.pd.nf.migu.cn/.../listenSong.do`（302 Location 为真链） | baka `mg.js`（本身全官方）、`music-lib/migu` | 无 |
| Bilibili | 官方 `api.bilibili.com/x/player/playurl`（DASH） | baka `bilibili.js`、`music-lib/bilibili` | 无 |
| 千千 qianqian | 官方 `music.91q.com/v1/song/tracklink` | `music-lib/qianqian` | 无 |
| 5sing | 官方 `mobileapi.5sing.kugou.com` | `music-lib/fivesing` | 无 |
| Jamendo | 官方 `www.jamendo.com/api/*` | `music-lib/jamendo` | 无 |
| JOOX | 官方 `api.joox.com` / `www.joox.com` 页面数据 | `music-lib/joox` | 无 |
| Apple | 官方 `amp-api.music.apple.com`（仅试听） | `music-lib/apple` | 无 |
| 汽水 soda | **仅官方**：PC API `api.qishui.com/luna/pc` + SEO `api.qishui.com/luna/h5/seo_track`（`video_model` 多档直链，会员 cookie 出 lossless/spatial/hi_res）+ VOD `*.douyinvod.com`；**放弃** Android `track_v2` | baka `qishui.js`（仅取官方部分）、`music-lib/soda` | `api.music.qishui.vsaa.cn`（个人第三方）、`api-vehicle.volcengine.com`（字节云但非汽水官方，不纳入） |

补充：

- QQ / 网易云 / 酷狗：baka 的 `requestMusicUrl` 第三方网关**不移植**，只用其**官方协议**部分
  （搜索/歌词/歌单/专辑/评论）与官方 `song_url`。
- 汽水若要**无损/空间音频**：**只能本地实现签名后直连官方**，绝不经 `vsaa.cn`
  （逐字歌词不在此列，官方 SEO 已可得）。
- 落地验收：新增平台的出站域名白名单必须只含该平台官方域名（可在测试中断言，
  参考 `app/test/` 现有注入式 transport 测试）。

---

## 9. 风险与缓解

| 风险 | 说明 | 缓解 |
|---|---|---|
| 平台风控变化 | 端点/签名随时失效 | 协议隔离在 `apis/<platform>/core`，可单点更新；加 `SearchSourceCooldown` 退避 |
| 加密算法复杂度 | 汽水 CENC、QQ QMC、酷狗设备注册易错 | 先做低/中难度源；高风险项后置并有单测对照 |
| 参考来源不可信 | `music-lib` 未随仓库分发，端点需复核 | 移植前 `go mod download github.com/guohuiyuan/music-lib@<commit>` 拉源码逐项核对 |
| gb18030 依赖 | 酷我歌词解码 | 评估 `charset`/`fast_gbk` 等（须 §9 登记）或内嵌最小码表 |
| 重构回归 | P0 触及播放/歌词/红心主链路 | 复用现有注入式单测 + 手动回归清单（`architecture.md` §12.2） |
| 汽水签名服务读取 sessionid | 第三方 `vsaa.cn` 能读到 sessionid | **不接入**该服务；只走纯官方 PC+SEO 路径，需无损时须先本地实现签名（§7-P4） |
| 本地签名逆向成本/失效 | `x-gorgon` 等为混淆/VM 实现，随版本失效 | P5 先做算法明确的（WBI/千千/酷我/咪咕）；失败静默降级，不影响播放 |
| 加密下载解密合规 | NCM/QMC/CENC 解密仅限自用已购/已授权内容 | 只做「格式互操作」，不破解付费墙、不绕过会员（§2.1）；来源逐项登记 |
| 代码重复 | 现有 `apis/kugou` 与 `services/kugou` 双实现 | P0 顺带收敛为单一实现 |

---

## 10. 请求去向审计（全平台）

> 方法：对每个插件的所有出站 URL 去重，并核对 `getMediaSource` / `requestMusicUrl` 调用链
> （2026-09-14 静态审计）。
> 结论：**所有平台的元数据（搜索/歌词/歌单/专辑/歌手/评论）请求都直达平台官方域名**；
> 唯一的第三方是 baka「源插件」的**播放 URL 解析**（委托第三方音源聚合服务）。
> 主项目对这些平台已有官方取流能力，移植时**用官方 `song_url` 即可，无需第三方音源**。

### 10.1 baka-plugins 各插件

| 插件 | 元数据/业务请求 | 播放 URL 解析 | 第三方域名 |
|---|---|---|---|
| `wy.js`（网易云） | ✅ 官方 `music.163.com` / `interface.music.163.com` / `interface3.music.163.com` | ⚠️ `requestMusicUrl('wy')` → 第三方音源（`wy.js:695`）；`share.duanx.cn/url/wy/...` 仅作字段（`wy.js:214/242`） | 音源聚合服务 |
| `qq.js` | ✅ 官方 `u.y.qq.com` / `c.y.qq.com` / `y.qq.com` / `y.gtimg.cn` | ⚠️ `requestMusicUrl('tx')`（`qq.js:469`） | 音源聚合服务 |
| `kg.js` | ✅ 官方 `*.kugou.com` | ⚠️ `requestMusicUrl('kg')`（`kg.js:930`） | 音源聚合服务 |
| `kw.js` | ✅ 官方 `*.kuwo.cn` | ⚠️ `requestMusicUrl('kw')`（`kw.js:853`） | 音源聚合服务 |
| `mg.js`（咪咕） | ✅ 官方 `*.migu.cn` | ✅ 自带 `requestMusicUrl`，全走官方咪咕（`mg.js:178/1366`） | 无 |
| `bilibili.js` | ✅ 官方 `api.bilibili.com` / `www.bilibili.com` / `s1.hdslb.com` | ✅ 自解析官方 DASH（`getMediaSource`） | 无 |
| `qishui.js`（汽水） | ✅ 官方 `api.qishui.com` / `beta-luna.douyin.com`；另有 `api-vehicle.volcengine.com`（字节火山引擎，非汽水官方，见 §7-P4） | ⚠️ Android `track_v2` 经第三方签名服务（`send:false`） | 签名服务 `api.music.qishui.vsaa.cn`（个人第三方） |

第三方音源聚合服务清单（`functions/source-config.js`）：
`c.wwwweb.top`(ikun)、`source.shiqianjiang.cn`(linglan)、`music-api.gdstudio.xyz`(cihedai)、
`musicapi.haitangw.net` / `music.haitangw.cc` / `175.27.166.236`(changqing)、`api.vkeys.cn` 等(quandouyao)、
`hywmusicsource.xn--9tra.work`(hyw)。这些服务收到 `{source, songId, quality}`（**不含账号凭据**），
仅用于换取播放直链。

### 10.2 go-music-dl / music-lib

- `go-music-dl` 自身出站：仅平台官方域名 + GitHub 代理（`gh-proxy.com` / `edgeone.gh-proxy.com` /
  `gh.llkk.cc`，仅「检查更新」）+ 占位图 `picsum.photos`。
- `music-lib`：各源直连官方域名，含随机 `X-Forwarded-For` / `X-Real-IP`（国内 IP 池）反爬，仍是官方端点。
- 结论：**无第三方音源聚合**，协议实现更接近主项目「官方直连」定位。

### 10.3 对主项目的结论

1. **全部可以做**：两个项目的平台业务请求都以官方域名为主，符合主项目「纯 Dart 直连官方平台」定位。
2. **不要移植第三方音源聚合**：baka 的 `wy/qq/kg/kw` 播放 URL 委托第三方；主项目已有官方
   `resolvePlayUrl`（netease/kugou/qqmusic），新增酷我/咪咕也应走**官方取流**（酷我官方接口、
   咪咕官方 `listenSong.do`），**不引入 `requestMusicUrl` 聚合层**。
3. **第三方一律隔离（硬约束，见 §8.1）**：
   - baka 源插件的音源聚合服务（`source-config.js`）——**不接入**。
   - 汽水签名服务 `vsaa.cn`（个人第三方）——**不接入**，只走纯官方路径（§7-P4）。
   - 字节火山引擎 `api-vehicle.volcengine.com`——非汽水官方域名，**不纳入白名单**（§7-P4）。
   - `share.duanx.cn`（`wy.js` 字段）——不移植。
4. **平台接入本身无合规红线问题**：审计显示业务请求均直达官方；两个项目仅作为**官方协议实现**的
   参考。落地时须保证新增平台出站域名**只含官方域名**。

---

## 11. 第三方音源请求方案分析（实测）

> 方法：从 `functions/plugin.js` 的 `generateRequestHandler`（`plugin.js:65-276`）提取每个 `apiType`
> 生成的请求代码，再于 2026-09-14 用**无密钥、无凭据**的单次探测请求实测各端点（12s 超时）。
> 结论：这些第三方本质是**「音源网关」**——输入 `{source, songId, quality}`，输出**平台官方 CDN 直链**
> （或 302 到官方 CDN）。它们不掌握账号、不提供超出官方的能力，且普遍有卡密 / 限速 / 易失效 /
> 质量阉割等问题。**按 §8.1 硬约束，这些网关一律不接入**——本节仅作协议/参数对照。

### 11.1 请求方案总表

| 音源(apiType) | 端点 | 方法/鉴权 | 请求 | 响应 |
|---|---|---|---|---|
| ikun | `https://c.wwwweb.top/music/url` | POST / `X-API-Key`（可空） | `{source, musicId, quality}` | `{code:200, ekey, quality, url}` |
| linglan | `https://source.shiqianjiang.cn/api/music/url` | GET / `X-API-Key`（卡密） | `?source=&songId=&quality=` | 需公益卡，否则 `{code:401}` |
| cihedai / GD | `https://music-api.gdstudio.xyz/api.php?use_xbridge3=true&loader_name=forest` | GET / 无 | `&types=url&source=netease&id=&br=` | `{url, br, size, from}` |
| cihedai / QQ | `https://tang.api.s01s.cn/music_open_api.php` | GET / 无 | `?mid=` | 元数据 + `song_play_url{,_sq,_hq,_standard,_fq}` |
| cihedai / KW | `http://music.nxinxz.com/kw.php` | GET / 无 | `?id=&level=&type=mp3` | 302 → 官方 `car-er.kuwo.cn` |
| changqing | `175.27.166.236/*.php`、`musicapi.haitangw.net`、`music.haitangw.cc` | GET / 无 | `?type=mp3&id=&level=` | 实测 404 / 空 |
| quandouyao / QQ | `https://api.vkeys.cn/v2/music/tencent/geturl` | GET / 无 | `?mid=&quality=` | `{code:200,data:{url,...}}` |
| quandouyao / WY | `https://api.bugpk.com/api/163_music` | GET / 无 | `?ids=&type=json&level=` | `{status:200,url,...}` |
| quandouyao / KW | `https://nmobi.kuwo.cn/mobi.s?...convert_url_with_sign` | GET / 无 | `?rid=&br=&user=&loginUid=` | `{code:200,data:{url}}` |
| quandouyao / KG | `https://music.haitangw.cc/kgqq/kg.php` | GET / 无 | `?type=mp3&id=&level=` | 需有效 hash |
| hyw | `http://hywmusicsource.xn--9tra.work/api/music/url` | GET / `X-Script-Version` + `X-Card-Key` | `?source=&songId=&quality=&key=` | 实测 404（路径变更） |

### 11.2 实测结果（2026-09-14，无密钥）

- **ikun**：`wy/tx/kg/kw` 均返回 200；wy/kw 给官方 CDN（`m801.music.126.net` / `car-er.kuwo.cn`），
  带 `ekey`（加密文件密钥，普通曲目为 `""`）。tx/kg 用网易 id 时返回同一个 `cdn-img.gitcode.com`
  兜底 URL（说明 id 不匹配时其兜底不可靠）。
- **gdstudio(cihedai)**：仅支持 `source=netease`；返回官方 `m701.music.126.net` 直链 + `br/size`。
- **s01s(cihedai QQ)**：返回官方 `isure6.stream.qqmusic.qq.com` 多档直链
  （`C600`≈128k、`F000`=flac 等）+ `vip` 标记。
- **vkeys(quandouyao QQ)**：返回官方 `ws.stream.qqmusic.qq.com`，但 `quality:"音乐试听"`
  （非会员仅试听）。
- **nxinxz(KW)**：302 → 官方 `car-er.kuwo.cn/.../M500...mp3`；`level` 映射
  `M500=128k / M800=320k / F000=flac`。
- **haitangw(KG)**：无效 id 返回 `{code:401,"error, has not any level"}`。
- **changqing / hyw**：实测 404 / 空（服务路径变更或下线）。
- **linglan**：401「请先登录用户面板申请公益卡」——卡密制。
- **qishui 签名服务**（`api.music.qishui.vsaa.cn`）：本机 15s 超时不可达（HTTP 80）。

### 11.3 结论

1. 这些第三方本质是**官方直链网关**（多数直接返回/302 到官方 CDN），**不提供官方之外的能力**，
   且有卡密、限速、易失效、质量阉割（试听）等问题——**不建议作为主链路**。
2. **隐私无新增风险**：请求只含 `{source, songId, quality}`，不含账号凭据（汽水签名服务除外）。
3. **可参考价值**：其参数映射可作为主项目官方取流实现的对照，例如
   酷我 `level→M500/M800/F000`、QQ 文件名前缀 `C600/F000`、`ekey`（加密文件密钥）字段、
   酷我 `convert_url_with_sign` 的 `br` 取值。
4. **主项目决策（硬约束）**：只做官方直连；第三方网关**一律不接入**（含「失效兜底」），
   也不移植其分发/订阅体系。

---

## 12. 附录：推荐阅读顺序（移植时对照）

**主项目**
- 架构：`docs/architecture.md` §2/§7/§10.2；`CONTRIBUTING.md` §2/§4/§9
- 模型：`app/lib/services/netease/track.dart`
- 范式：`app/lib/services/streaming/streaming_client.dart`、`app/lib/apis/runtime.dart`
- 分发点：`playback_notifier_queue.dart:11`、`lyrics_provider.dart:40`、`like_controller.dart`

**baka-plugins（`https://github.com/Zencok/baka-plugins`）**
- 契约/分发：`functions/plugin.js`、`functions/source-config.js`、`functions/subscription.js`
- 分页契约：`docs/playlist-import-pagination.md`
- 平台：`plugins/{wy,qq,kg,kw,mg,bilibili,qishui}.js`

**go-music-dl（`https://github.com/guohuiyuan/go-music-dl`）**
- 编排/源清单：`core/service.go`（`:148` 起工厂、`:1005` 源清单、`:895` 相似度、`:1324` Range）
- 下载/元数据：`core/download.go`、`core/service.go:1589`
- 自动换源：`internal/web/music.go:1321`
- 协议实现：外部 `github.com/guohuiyuan/music-lib`（`https://github.com/guohuiyuan/music-lib`）
