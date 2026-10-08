// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// NekoMusic 音源的客户端标识。
///
/// NekoMusic 服务端有两道校验：
///
/// 1. **防爬 / 客户端区分（只看 `User-Agent`）**——见《防爬与客户端识别》：
///    - 未知 UA：`POST` → `403`；`GET` → 直出对应 **SEO HTML**（非 JSON / 音频）；
///    - **空 `User-Agent` → 直接放行**（为不发 UA 的桌面端保留的路径）；
///    - 命中内置白名单（`okhttp` / `qt` / `ffmpeg` / `nekomusic` …）或
///      「像真浏览器 + 特征头」亦放行。
///    我们既不在其内置品牌白名单、也不冒名官方客户端，故按文档的**空 UA 放行**
///    路径走：把 `User-Agent` 显式置空（`dart:io` 默认 UA `Dart/…` 同样会被拦），
///    客户端身份改由 [kNekoClientHeader] 表达。FFmpeg AVIO 侧需同样发空 UA
///    （见 `app/core/audio-engine/src/decoder.c` 的 `decoder_apply_http_headers`）。
/// 2. **请求防重放**——见《请求防重放》：全部动态接口（`/api/*`、`/loser/*`）
///    需一次性 `X-Neko-Nonce`（绑定 IP + 读/写、120s、用后即废），缺失/重放
///    返回 `409`。由 `apis/neko/neko_client.dart` 的 nonce 池自动领取并注入。
///
/// 例外是**站点图片**（封面 / 头像）：它们经全局 HttpClient（浏览器 UA，见
/// `main.dart` 的 `_BrowserUserAgentOverrides`）发起，`Image` / `NetworkImage`
/// 以 `add` 语义追加请求头、**无法清空 UA**，故改走「浏览器完整性」放行路径——
/// 补齐 `Accept` + `Accept-Language`（`dart:io` 默认不发 `Accept`），配合全局
/// 浏览器 UA 即可放行；封面 / 头像本身也在防重放豁免清单内。
library;

import '../../utils/app_version.dart';

/// 端名：客户端标识 `<端>+<版本>` 的前半段。
const String kClientName = 'archoera';

/// 客户端标识头名（见后端《防爬与客户端识别》专项文档；供服务端识别来源）。
const String kNekoClientHeader = 'X-Neko-Client';

/// 防重放 nonce 请求头（服务端对全部动态 `/api/*`、`/loser/*` 强制要求）。
///
/// 见后端《请求防重放》专项文档：一次性、绑定「客户端 IP + 读/写类别」、
/// 默认 120s 过期；缺失/重放/过期返回 `409`。
const String kNekoNonceHeader = 'X-Neko-Nonce';

/// 防重放失败原因响应头（`missing` / `invalid`；据此决定换 nonce 重试一次）。
const String kNekoReplayStatusHeader = 'X-Neko-Replay-Status';

/// 版本占位：读取失败时用 `unknown`（服务端放行不依赖版本）。
String get _versionOrUnknown =>
    clientVersion.isEmpty ? 'unknown' : clientVersion;

/// 客户端标识值：`archoera+<版本>`。
String get nekoClientValue => '$kClientName+$_versionOrUnknown';

/// 发往 NekoMusic 的完整请求头（REST / SSE / 音频下载 / 引擎 AVIO / 原生 HTTP）。
///
/// `User-Agent` 显式置空 = 服务端「空 UA 放行」路径（详见库注释）。
Map<String, String> get nekoRequestHeaders => {
      'User-Agent': '',
      kNekoClientHeader: nekoClientValue,
    };

/// 发往 NekoMusic 站点图片（封面 / 头像）的请求头。
///
/// 图片经全局浏览器 UA 发起、无法清空 UA；补齐 `Accept` + `Accept-Language`
/// 走服务端「浏览器完整性」放行路径（详见库注释）。
Map<String, String> get nekoClientHeaderOnly => {
      kNekoClientHeader: nekoClientValue,
      'Accept': 'image/*',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
    };

/// 媒体请求头解析器：命中 NekoMusic 站点的图片资源（封面 / 头像）时返回标识头。
///
/// 由 `services/source/media_request_headers.dart` 注册到全局解析表，供各图片工具
/// （`Image.network` / `NetworkImage`）统一取用，避免各 widget 直接依赖本源。
Map<String, String>? nekoMediaHeaderResolver(Uri uri) {
  final path = uri.path;
  if (path.startsWith('/api/music/cover/') ||
      path.startsWith('/api/user/avatar/')) {
    return nekoClientHeaderOnly;
  }
  return null;
}
