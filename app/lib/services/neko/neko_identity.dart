// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// NekoMusic 音源的出站请求头。
///
/// NekoMusic 服务端已移除客户端的 PoW、防重放 nonce 与实例指纹校验
/// （服务端不再识别 `X-Neko-Client-*` / `X-Neko-Nonce`，对应接口已下线）。
/// 现在请求只需要常规 HTTP 头 + 用户 Token：
///
/// - `User-Agent`：官方锚定的 `NekoMusic-PC/<数字版本>`。服务端只把它用于
///   SEO 页面 / SPA 壳的表示选择，**不参与 API 鉴权**；缺失或未知形状会被
///   降级为 SEO HTML，所以这里保持官方形状。
/// - `Accept-Language`：仅影响响应 `message` 文案（zh-CN / zh-TW / en / ja / ko）。
/// - `Authorization: Bearer <token>`：登录令牌，由 `NekoClient` 注入。
///
/// 站点图片（封面 / 头像）经全局 HttpClient（浏览器 UA）发起，`Image.network`
/// 以 `add` 语义追加请求头、无法覆盖 UA，故图片侧只补 `Accept` /
/// `Accept-Language`，不附加任何身份头。
library;

import '../../utils/app_version.dart';

/// 出站 UA：官方锚定的 PC 客户端形状 `NekoMusic-PC/<版本>`。
///
/// 版本必须以数字开头（服务端正则要求）；读取失败回退 `0`。
String get nekoUserAgent =>
    'NekoMusic-PC/${clientVersion.isEmpty ? '0' : clientVersion}';

/// 发往 NekoMusic 的通用请求头（REST / SSE / 媒体下载 / 引擎 AVIO）。
///
/// 不含身份签名：新协议只认 `Authorization` 用户令牌。
Map<String, String> get nekoRequestHeaders => {
      'User-Agent': nekoUserAgent,
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
    };

/// 媒体请求头解析器：命中 NekoMusic 站点的图片资源（封面 / 头像）时返回
/// 图片侧需要的头（UA 由全局 HttpClient 决定，不能再覆盖）。
Map<String, String>? nekoMediaHeaderResolver(Uri uri) {
  final path = uri.path;
  if (path.startsWith('/api/music/cover/') ||
      path.startsWith('/api/user/avatar/')) {
    return const {
      'Accept': 'image/*',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
    };
  }
  return null;
}
