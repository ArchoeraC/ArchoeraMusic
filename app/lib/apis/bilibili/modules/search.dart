// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Bilibili 视频搜索（`/x/web-interface/wbi/search/type`）。
library;

import '../core/request.dart';
import '../core/types.dart';

/// 搜索视频。`page` 从 1 开始，`pageSize` 最大 20（B 站接口上限）。
Future<BilibiliSearchPage> bilibiliSearchVideos(
  BilibiliRequest request,
  String keyword, {
  int page = 1,
  int pageSize = 20,
}) async {
  final text = keyword.trim();
  if (text.isEmpty) {
    return BilibiliSearchPage(
      items: const [],
      total: 0,
      page: page,
      hasMore: false,
    );
  }
  final size = pageSize < 1 ? 1 : (pageSize > 20 ? 20 : pageSize);
  final root = await request.getJson(
    '/x/web-interface/wbi/search/type',
    signed: true,
    params: {
      'search_type': 'video',
      'keyword': text,
      'page': '$page',
      'page_size': '$size',
    },
  );
  final data = bilibiliData(root);
  final raw = data['result'];
  final rows = raw is List ? raw : const [];
  final items = <BilibiliSearchItem>[];
  for (final entry in rows) {
    if (entry is! Map) continue;
    final row = Map<String, dynamic>.from(entry);
    final bvid = row['bvid']?.toString() ?? '';
    if (!isBilibiliBvid(bvid)) continue;
    final title = _cleanText(row['title']);
    if (title.isEmpty) continue;
    items.add(
      BilibiliSearchItem(
        bvid: bvid,
        title: title,
        author: _cleanText(row['author']),
        cover: bilibiliHttpsUrl(row['pic']),
        durationMs: bilibiliDurationMs(row['duration']),
      ),
    );
  }

  final current = _asInt(data['page']) ?? page;
  final total = _asInt(data['numResults']) ?? items.length;
  final pages = _asInt(data['numPages']) ?? current;
  return BilibiliSearchPage(
    items: items,
    total: total,
    page: current,
    hasMore: items.isNotEmpty && current < pages,
  );
}

String _cleanText(Object? raw) {
  var text = raw?.toString() ?? '';
  text = text.replaceAll(RegExp(r'<[^>]*>'), '');
  text = text
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&');
  return text.trim();
}

int? _asInt(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}
