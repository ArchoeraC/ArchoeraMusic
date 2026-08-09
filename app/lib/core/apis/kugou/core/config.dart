/// KG API 通用常量——对齐 apis/kugou/core/config.ts。
library;

/// 主搜索（带封面）：mobilecdn 的 /api/v3/search/song
const kgMobilecdnUrl = 'http://mobilecdn.kugou.com/api/v3/search/song';

/// 兜底搜索：老的 songsearch（无封面）
const kgSearchUrl = 'https://songsearch.kugou.com/song_search_v2';

/// 歌词搜索/下载接口（lyrics.kugou.com）
const kgLyricSearchUrl = 'http://lyrics.kugou.com/search';
const kgLyricDownloadUrl = 'http://lyrics.kugou.com/download';

/// 歌词接口需要的伪装 headers（KuGou2012 PC 客户端）
final Map<String, String> kgLyricHeaders = {
  'KG-RC': '1',
  'KG-THash': 'expand_search_manager.cpp:852736169:451',
  'User-Agent': 'KuGou2012-9020-ExpandSearchManager',
};

const Map<String, String> _entityMap = {
  '&nbsp;': ' ',
  '&amp;': '&',
  '&lt;': '<',
  '&gt;': '>',
  '&quot;': '"',
  '&apos;': "'",
  '&#039;': "'",
};

/// HTML 实体反转义
String kgDecodeName(String? str) {
  if (str == null || str.isEmpty) return '';
  var out = str;
  _entityMap.forEach((k, v) => out = out.replaceAll(k, v));
  return out;
}

/// 歌手数组 `[{name:'A'},{name:'B'}]` → `A / B`
String kgFormatSingerName(List<dynamic>? singers, [String join = ' / ']) {
  if (singers == null || singers.isEmpty) return '';
  return singers
      .map((s) => s is Map ? s['name'] : null)
      .whereType<String>()
      .map(kgDecodeName)
      .join(join);
}

/// `MM:SS` / `HH:MM:SS` 格式时长字符串 → 秒
int kgIntervalToSeconds(Object? interval) {
  if (interval is num) return interval.floor();
  if (interval == null) return 0;
  final parts = '$interval'.split(':').map(int.tryParse).toList();
  var seconds = 0;
  var unit = 1;
  while (parts.isNotEmpty) {
    final v = parts.removeLast();
    if (v != null) seconds += v * unit;
    unit *= 60;
  }
  return seconds;
}
