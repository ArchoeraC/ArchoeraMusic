// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Bilibili 音源固定配置。
///
/// 只访问 B 站官方域名（api/passport/www 与官方 CDN）；不引入任何第三方
/// 解析网关。协议事实参考社区公开资料，代码为独立 Dart 实现。
library;

/// 请求 UA（桌面浏览器）。B 站部分接口对默认 Dart UA 返回 412。
const String kBilibiliUserAgent =
    'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';

/// 站内请求 Referer（搜索、详情、取流均要求）。
const String kBilibiliReferer = 'https://www.bilibili.com/';

const String kBilibiliApiBase = 'https://api.bilibili.com';
const String kBilibiliPassportBase = 'https://passport.bilibili.com';

/// 宿主会话存储键（vault 加密）。
const String kBilibiliSessionPlatform = 'bilibili';

/// 允许持久化的 Cookie 白名单。
///
/// 登录只需要这组凭据；不把浏览器里其它 B 站 Cookie 带进本应用。
const Set<String> kBilibiliCookieNames = {
  'SESSDATA',
  'bili_jct',
  'DedeUserID',
  'DedeUserID__ckMd5',
  'buvid3',
  'buvid4',
};
