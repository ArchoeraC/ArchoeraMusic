// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// QM API 通用常量——对齐 apis/qqmusic/core/config.ts。
library;

/// 统一接口入口（移动端 musicu）
const qmApiUrl = 'https://u.y.qq.com/cgi-bin/musicu.fcg';

/// 桌面端接口入口（musics.fcg）——需 `?sign=`（见 core/sign.dart `qmZzcSign`）。
/// 配合 `comm.ct=19` 下发完整音质字段（`size_hires`/`size_new`/`size_dolby` 等）。
const qmDesktopApiUrl = 'https://u.y.qq.com/cgi-bin/musics.fcg';

/// 模拟移动端的默认 headers
final Map<String, String> qmHeaders = {
  'Content-Type': 'application/json',
  'Accept-Encoding': 'gzip',
  'User-Agent': 'QQMusic 14090008(android 15)',
  'Referer': 'https://y.qq.com',
};

/// 请求体 comm 字段（伪装 Android 客户端）
Map<String, Object> qmGetCommonParams() => {
  'ct': 11,
  'cv': 14090008,
  'v': 14090008,
  'chid': '10003505',
  'os_ver': '15',
  'phonetype': '24122RKC7C',
  'tmeAppID': 'qqmusic',
  'nettype': 'NETWORK_WIFI',
  'udid': '0',
  'OpenUDID': '0',
  'QIMEI36': '0',
  'uin': '0',
};

/// Session 缓存时长（毫秒）
const qmSessionTtl = 60 * 60 * 1000;

/// 网页 UA（song_url / 扫码登录等 Web 接口使用）
const qmWebUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

/// 归一 QQ 封面 / 头像 URL。
///
/// QQ 各 CDN（`y.gtimg.cn`、`qpic.y.qq.com`、`q.qlogo.cn` 等）会返回三种形态：
/// - `https://...`（保持）；
/// - `http://...`（明文，桌面端可能加载失败 / 移动端被拦截）；
/// - 协议相对 `//host/...`（**无 scheme**，会被 `CoverImage` 误判为本地文件，
///   直接显示占位图）。
///
/// 统一升级为 `https://`；空值返回 `''`。收藏歌单封面（`logo`）此前正是因
/// `//` 未归一而显示不出来。
String qmNormalizeCover(String? url) {
  final u = url?.trim() ?? '';
  if (u.isEmpty) return '';
  if (u.startsWith('//')) return 'https:$u';
  if (u.startsWith('http://')) return 'https://${u.substring(7)}';
  return u;
}

/// 歌手数组格式化工具：`[{name:'A'},{name:'B'}]` → `A / B`
String qmFormatSingerName(
  List<dynamic>? singers, {
  String key = 'name',
  String join = ' / ',
}) {
  if (singers == null || singers.isEmpty) return '';
  return singers
      .map((item) => item is Map ? item[key] : null)
      .whereType<String>()
      .where((s) => s.isNotEmpty)
      .join(join);
}
