// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 媒体请求头注册表。
///
/// 封面 / 头像等图片由全局 HttpClient 发起，无法像 API 请求那样在调用点注入完整
/// 请求头（`Image.network` 以 `add` 语义追加，写 UA 会与全局默认 UA 叠成双头）。
/// 各音源模块把自己的「URL → 请求头」规则登记到本表，图片工具统一调用
/// [mediaHeadersForUrl] 取头——新增音源只需在此加一条解析器，无需改各 widget。
library;

import '../neko/neko_identity.dart';

/// 单条媒体请求头解析器：命中则返回需附加的请求头，否则返回 null。
typedef MediaHeaderResolver = Map<String, String>? Function(Uri uri);

/// 已注册解析器（顺序即匹配优先级）。
final List<MediaHeaderResolver> _resolvers = <MediaHeaderResolver>[
  nekoMediaHeaderResolver,
];

/// 解析某媒体 URL 对应的请求头；未命中返回 null。
Map<String, String>? mediaHeadersForUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  for (final resolve in _resolvers) {
    final headers = resolve(uri);
    if (headers != null && headers.isNotEmpty) return headers;
  }
  return null;
}
