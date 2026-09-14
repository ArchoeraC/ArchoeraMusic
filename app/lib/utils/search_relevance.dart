// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 聚合搜索「匹配度」排序：跨平台统一口径，按查询与条目文本的相关度排序，
/// 而不是按来源优先级排列。
library;

final RegExp _strip = RegExp(
  r"[\s\-_/、,，.。·・()（）\[\]【】'`~!?？！&]+",
);

/// 版本/非原唱标记（标题含这些词 → 降权，让原唱更靠前）。
final RegExp _versionRe = RegExp(
  r'live|演唱会|伴奏|翻唱|cover|remix|混音|片段|试听|铃声|纯音乐|钢琴|吉他|'
  r'尤克里里|口琴|女声|男声|合唱|对唱|dj|慢摇|电音|抖音|热歌|'
  r'instrumental|karaoke|acoustic|demo',
  caseSensitive: false,
);

bool _isVersioned(String title) => _versionRe.hasMatch(title);

String _norm(String? s) => (s ?? '').toLowerCase().replaceAll(_strip, '');

Set<String> _bigrams(String s) {
  final out = <String>{};
  if (s.length == 1) {
    out.add(s);
    return out;
  }
  for (var i = 0; i + 2 <= s.length; i++) {
    out.add(s.substring(i, i + 2));
  }
  return out;
}

/// 字符二元组 Dice 系数（0..1）。
double _dice(String a, String b) {
  if (a.isEmpty || b.isEmpty) return 0;
  if (a == b) return 1;
  final ag = _bigrams(a);
  final bg = _bigrams(b);
  if (ag.isEmpty || bg.isEmpty) return 0;
  var inter = 0;
  for (final g in ag) {
    if (bg.contains(g)) inter++;
  }
  return 2 * inter / (ag.length + bg.length);
}

/// 聚合搜索相关度（越大越相关）：标题命中权重最高，其次歌手 / 专辑。
///
/// 对 [query] 与 `title`/`artist`/`album` 归一化后打分：标题全等/前缀/包含/
/// 反向包含给高权重，再用二元组 Dice 做模糊相似度兜底。
///
/// **原唱优先**（避免「翻唱/伴奏/Live 排在原唱前」）：
/// - 查询含歌手名（`q` 包含 `a`）→ 加分（点播歌手时该歌手条目靠前）；
/// - 标题含版本/非原唱标记（Live/伴奏/翻唱/remix…）→ 降权。
double searchRelevanceScore(
  String query,
  String title,
  String artist, [
  String? album,
]) {
  final q = _norm(query);
  if (q.isEmpty) return 0;
  final t = _norm(title);
  final a = _norm(artist);
  var s = 0.0;
  if (t.isNotEmpty) {
    if (t == q) {
      s += 100;
    } else if (t.startsWith(q)) {
      s += 70;
    } else if (t.contains(q)) {
      s += 50;
    } else if (q.contains(t)) {
      s += 35;
    }
  }
  s += 60 * _dice(q, t);
  s += 25 * _dice(q, a);
  // 注意：不要再叠加 `dice(q, t+a)`。当查询就是歌名（q == t）时，`t+a` 的
  // 二元组数量随歌手名长度增长，反而让「歌名相同、歌手名更短」的翻唱排在
  // 原唱前（如 三拜红尘凉：黄龄/酒禾 > 原唱尹昔眠）。歌手相关度已由上面的
  // `dice(q, a)` 与下方 `q.contains(a)` 覆盖，同分时保持各源原生名次即可。
  if (album != null && album.isNotEmpty) s += 8 * _dice(q, _norm(album));
  // 原唱优先：查询点明歌手时，歌手命中加分。
  if (a.isNotEmpty && q.contains(a)) s += 40;
  // 版本降权：Live / 伴奏 / 翻唱 / remix 等。
  if (_isVersioned(title)) s -= 30;
  return s;
}

/// 按 [searchRelevanceScore] 降序稳定排序（同分保持原有顺序）。
List<T> sortByRelevance<T>(
  String query,
  List<T> items,
  double Function(T) scoreOf,
) {
  final indexed = List.generate(items.length, (i) => (i, items[i]));
  indexed.sort((x, y) {
    final c = scoreOf(y.$2).compareTo(scoreOf(x.$2));
    return c != 0 ? c : x.$1.compareTo(y.$1);
  });
  return [for (final e in indexed) e.$2];
}
