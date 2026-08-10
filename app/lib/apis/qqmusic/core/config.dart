/// QM API 通用常量——对齐 apis/qqmusic/core/config.ts。
library;

/// 统一接口入口（移动端 musicu）
const qmApiUrl = 'https://u.y.qq.com/cgi-bin/musicu.fcg';

/// 模拟移动端的默认 headers
final Map<String, String> qmHeaders = {
  'Content-Type': 'application/json',
  'Accept-Encoding': 'gzip',
  'User-Agent': 'okhttp/3.14.9',
  'Referer': 'https://y.qq.com',
  'Cookie': 'tmeLoginType=-1;',
};

/// 请求体 comm 字段（伪装 Android 客户端）
Map<String, Object> qmGetCommonParams() => {
      'ct': 11,
      'cv': '1003006',
      'v': '1003006',
      'os_ver': '15',
      'phonetype': '24122RKC7C',
      'tmeAppID': 'qqmusiclight',
      'nettype': 'NETWORK_WIFI',
      'udid': '0',
      'OpenUDID': '0',
      'QIMEI36': '0',
      'uin': '0',
    };

/// Session 缓存时长（毫秒）
const qmSessionTtl = 60 * 60 * 1000;

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
