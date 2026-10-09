// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// NekoMusic 音源的客户端标识。
///
/// NekoMusic 服务端的客户端校验（见后端《防爬与客户端识别》专项文档）：
/// - 空 / 缺失 `User-Agent` → 一律按爬虫处理（`GET` 直出 SEO HTML、其它方法
///   `403`），**旧版「空 UA 放行」旁路已拆除**；
/// - 官方原生客户端 UA 为**整体锚定**的 `NekoMusic-<平台>/<版本>`
///   （平台限 `android|pc|ios|macos|windows|linux|qt`，版本必须以数字开头）；
/// - 未知 UA（既非浏览器完整性、也非官方 UA）同样被降级为 SEO HTML。
///
/// 经实测，服务端**不认** `ArchoeraMusic/<版本>` 这类自报 UA：在换题等动态接口上
/// 会被降级为 SEO HTML。因此本客户端**不再保留「本体 UA 主路径」**——所有 Neko
/// 出站请求一律使用官方锚定的桌面 UA **形状** `NekoMusic-<平台>/<版本>`，并始终携带
/// `X-Neko-Client: archoera+<版本>` 作为**来源声明**：复用其公开形状只为通过
/// `isNativeClient` 正则，**不冒名官方品牌、不伪装 Android、不做浏览器对抗**；
/// 服务端一旦落地「自报标识 `X-Neko-Client` 作为正向证据」的放行逻辑，该头即自动生效。
///
/// 例外是**站点图片**（封面 / 头像）：它们经全局 HttpClient（浏览器 UA，见
/// `main.dart` 的 `_BrowserUserAgentOverrides`）发起，`Image` / `NetworkImage`
/// 以 `add` 语义追加请求头、**无法清空 / 覆盖 UA**，因此图片侧只补标识头与浏览器
/// 特征头（封面 / 头像本身也在防重放豁免清单内）。
library;

import 'dart:io';

import '../../utils/app_version.dart';

/// 端名：客户端标识 `<端>+<版本>` 的前半段。
const String kClientName = 'archoera';

/// 客户端标识头名（见后端《防爬与客户端识别》专项文档；供服务端识别来源）。
const String kNekoClientHeader = 'X-Neko-Client';

/// 防重放 nonce 请求头（服务端对全部动态 `/api/*`、`/loser/*` 强制要求）。
///
/// 见后端《请求防重放》专项文档：一次性、绑定「客户端 IP + 读/写类别」、
/// 短时有效；缺失/重放/过期返回 `409`。
const String kNekoNonceHeader = 'X-Neko-Nonce';

/// 防重放失败原因响应头（`missing` / `invalid`；据此决定换 nonce 重试一次）。
const String kNekoReplayStatusHeader = 'X-Neko-Replay-Status';

/// 版本占位：读取失败时用 `unknown`（`X-Neko-Client` 里表达真实来源）。
String get _versionOrUnknown =>
    clientVersion.isEmpty ? 'unknown' : clientVersion;

/// 官方 UA 正则要求版本以数字开头：未知 / 空版本回退 `0`（仍能命中）。
String get _versionWithLeadingDigit =>
    clientVersion.isEmpty ? '0' : clientVersion;

/// 客户端标识值：`archoera+<版本>`。
String get nekoClientValue => '$kClientName+$_versionOrUnknown';

/// 当前平台标识：命中服务端官方 UA 正则接受的桌面平台（`windows|macos|linux`）。
String get nekoPlatformName {
  if (Platform.isWindows) return 'windows';
  if (Platform.isMacOS) return 'macos';
  return 'linux';
}

/// 出站 UA：官方锚定的桌面 UA 形状 `NekoMusic-<平台>/<版本>`。
///
/// 只复用其公开形状以通过服务端 `isNativeClient` 锚定正则；来源声明由
/// [nekoClientValue] 的 `X-Neko-Client` 承担，不冒名官方品牌、不伪装 Android。
String get nekoUserAgent => 'NekoMusic-$nekoPlatformName/$_versionWithLeadingDigit';

/// 发往 NekoMusic 的完整请求头（REST / SSE / 音频下载 / 引擎 AVIO / 原生 HTTP）。
///
/// `User-Agent` 始终为官方锚定的桌面形状（非空）；`X-Neko-Client` 始终表达真实来源。
Map<String, String> get nekoRequestHeaders => {
      'User-Agent': nekoUserAgent,
      kNekoClientHeader: nekoClientValue,
    };

/// 发往 NekoMusic 站点图片（封面 / 头像）的请求头。
///
/// 图片经全局浏览器 UA 发起、无法覆盖 UA，故只补标识头与浏览器特征头：
/// 服务端靠 `X-Neko-Client` 或浏览器完整性放行（详见库注释）。
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
