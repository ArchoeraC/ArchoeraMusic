// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 聚合搜索「匹配度」排序：跨平台统一口径，按查询与条目文本的相关度排序，
/// 而不是按来源优先级排列。
library;

final RegExp _strip = RegExp(
  r"[\s\-_/、,，.。·・()（）\[\]【】'`~!?？！&]+",
);

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
  s += 15 * _dice(q, '$t$a');
  if (album != null && album.isNotEmpty) s += 8 * _dice(q, _norm(album));
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
