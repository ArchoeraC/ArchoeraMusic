// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// NekoMusic 音源的客户端标识。
///
/// NekoMusic 走统一 REST；服务端防爬对 `/api/*` 会区分客户端。我们**仅对发往
/// NekoMusic 的请求**附加标识：
/// - REST / SSE / 音频下载：`User-Agent: ArchoeraMusic/<版本>` + `X-Neko-Client`；
/// - 站点图片（封面 / 头像，经全局 HttpClient）：仅 `X-Neko-Client`（`Image.network`
///   以 `headers.add` 追加，再带 UA 会与全局浏览器 UA 叠成双头）。
///
/// 全局 HttpClient 默认 UA 仍是浏览器 UA（第三方 CDN 需要，见 main.dart），
/// **不在此覆盖**；服务端亦不针对本客户端做品牌白名单，放行完全靠通用标识头。
library;

import '../../utils/app_version.dart';

/// 端名：客户端标识 `<端>+<版本>` 的前半段。
const String kClientName = 'archoera';

/// 产品名：Neko 请求 UA `ArchoeraMusic/<版本>` 的前缀（与实际产品名一致）。
const String kProductName = 'ArchoeraMusic';

/// 客户端标识头名（见后端 `API-防爬与客户端识别.md`）。
const String kNekoClientHeader = 'X-Neko-Client';

/// 版本占位：读取失败时用 `unknown`（后端按标识放行，不依赖版本）。
String get _versionOrUnknown =>
    clientVersion.isEmpty ? 'unknown' : clientVersion;

/// NekoMusic 请求专用 User-Agent：`ArchoeraMusic/<版本>`（非全局）。
String get nekoUserAgent => '$kProductName/$_versionOrUnknown';

/// 客户端标识值：`archoera+<版本>`。
String get nekoClientValue => '$kClientName+$_versionOrUnknown';

/// 发往 NekoMusic 的完整请求头（REST / SSE / 音频下载）。
Map<String, String> get nekoRequestHeaders => {
      'User-Agent': nekoUserAgent,
      kNekoClientHeader: nekoClientValue,
    };

/// 发往 NekoMusic 的标识头（仅 [kNekoClientHeader]，供站点图片附加）。
Map<String, String> get nekoClientHeaderOnly => {
      kNekoClientHeader: nekoClientValue,
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
