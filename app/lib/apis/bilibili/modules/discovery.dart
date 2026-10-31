// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// B 站发现页数据：新歌 / 音乐推荐 / 热门音乐 / 关注更新。
///
/// 公开三区不需要登录；关注更新需要账号会话。
library;

import '../core/request.dart';
import '../core/types.dart';

Future<BilibiliTrackPage<BilibiliSearchItem>> bilibiliDiscovery(
  BilibiliRequest request,
  String section, {
  String? cursor,
}) async {
  switch (section) {
    case 'newSongs':
      return _newSongs(request);
    case 'recommendations':
      return _recommendations(request, cursor);
    case 'popular':
      return _popular(request);
    case 'following':
      return _following(request, cursor);
    default:
      throw const BilibiliApiException(
        'Invalid Bilibili discovery section.',
        kind: BilibiliErrorKind.invalidRequest,
      );
  }
}

Future<BilibiliTrackPage<BilibiliSearchItem>> _newSongs(
  BilibiliRequest request,
) async {
  final root = await request.getJson('/x/centralization/interface/new/music');
  final data = bilibiliData(root);
  final raw = data['list'];
  if (raw is! List) {
    throw const BilibiliApiException(
      'Bilibili new music response is incomplete.',
      kind: BilibiliErrorKind.invalidResponse,
    );
  }
  final items = <BilibiliSearchItem>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final row = Map<String, dynamic>.from(entry);
    final bvid = row['bvid']?.toString() ?? '';
    if (!isBilibiliBvid(bvid)) continue;
    final title = _cleanText(row['music_title']);
    if (title.isEmpty) continue;
    final cid = _asInt(row['cid']);
    items.add(
      BilibiliSearchItem(
        bvid: bvid,
        title: title,
        author: _cleanText(row['author']),
        cover: bilibiliHttpsUrl(row['cover']),
        durationMs: 0,
        cid: cid != null && cid > 0 ? '$cid' : null,
      ),
    );
  }
  return BilibiliTrackPage(items: items);
}

Future<BilibiliTrackPage<BilibiliSearchItem>> _popular(
  BilibiliRequest request,
) async {
  final root = await request.getJson(
    '/x/centralization/interface/music/comprehensive/web/rank',
  );
  final data = bilibiliData(root);
  final raw = data['list'];
  if (raw is! List) {
    throw const BilibiliApiException(
      'Bilibili popular music response is incomplete.',
      kind: BilibiliErrorKind.invalidResponse,
    );
  }
  final items = <BilibiliSearchItem>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final row = Map<String, dynamic>.from(entry);
    final related = row['related_archive'];
    final video = related is Map ? Map<String, dynamic>.from(related) : row;
    final bvid = video['bvid']?.toString() ?? '';
    if (!isBilibiliBvid(bvid)) continue;
    final title = _cleanText(video['title'] ?? row['music_title']);
    if (title.isEmpty) continue;
    final cid = _asInt(video['cid']);
    items.add(
      BilibiliSearchItem(
        bvid: bvid,
        title: title,
        author: _cleanText(video['username'] ?? row['author']),
        cover: bilibiliHttpsUrl(video['cover'] ?? row['cover']),
        durationMs: bilibiliDurationMs(video['duration']),
        cid: cid != null && cid > 0 ? '$cid' : null,
      ),
    );
  }
  return BilibiliTrackPage(items: items);
}

Future<BilibiliTrackPage<BilibiliSearchItem>> _recommendations(
  BilibiliRequest request,
  String? cursor,
) async {
  final batch = cursor == null || cursor.isEmpty ? 1 : int.tryParse(cursor);
  if (batch == null || batch < 1 || batch > 100) {
    throw const BilibiliApiException(
      'Invalid Bilibili recommendation cursor.',
      kind: BilibiliErrorKind.invalidRequest,
    );
  }
  final root = await request.getJson(
    '/x/web-interface/region/feed/rcmd',
    signed: true,
    params: {
      'from_region': '1003',
      'display_id': '$batch',
      'request_cnt': '15',
      'device': 'web',
      'plat': '30',
    },
  );
  final data = bilibiliData(root);
  final raw = data['archives'];
  if (raw is! List) {
    throw const BilibiliApiException(
      'Bilibili recommendation response is incomplete.',
      kind: BilibiliErrorKind.invalidResponse,
    );
  }
  final items = <BilibiliSearchItem>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final row = Map<String, dynamic>.from(entry);
    final bvid = row['bvid']?.toString() ?? '';
    if (!isBilibiliBvid(bvid)) continue;
    final title = _cleanText(row['title']);
    if (title.isEmpty) continue;
    final author = row['author'];
    final cid = _asInt(row['cid']);
    items.add(
      BilibiliSearchItem(
        bvid: bvid,
        title: title,
        author: author is Map ? _cleanText(author['name']) : '',
        cover: bilibiliHttpsUrl(row['cover']),
        durationMs: bilibiliDurationMs(row['duration']),
        cid: cid != null && cid > 0 ? '$cid' : null,
      ),
    );
  }
  return BilibiliTrackPage(
    items: items,
    nextCursor: items.length >= 15 && batch < 100 ? '${batch + 1}' : null,
  );
}

Future<BilibiliTrackPage<BilibiliSearchItem>> _following(
  BilibiliRequest request,
  String? cursor,
) async {
  if (cursor != null && cursor.length > 256) {
    throw const BilibiliApiException(
      'Invalid Bilibili following cursor.',
      kind: BilibiliErrorKind.invalidRequest,
    );
  }
  final params = <String, String>{'type': 'video', 'platform': 'web'};
  if (cursor != null && cursor.isNotEmpty) params['offset'] = cursor;
  final root = await request.getJson(
    '/x/polymer/web-dynamic/v1/feed/all',
    params: params,
  );
  final data = bilibiliData(root);
  final raw = data['items'];
  if (raw is! List) {
    throw const BilibiliApiException(
      'Bilibili following response is incomplete.',
      kind: BilibiliErrorKind.invalidResponse,
    );
  }
  final items = <BilibiliSearchItem>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final row = Map<String, dynamic>.from(entry);
    if (row['type']?.toString() != 'DYNAMIC_TYPE_AV') continue;
    if (row['visible'] == false) continue;
    final modules = row['modules'];
    if (modules is! Map) continue;
    final dynamicModule = modules['module_dynamic'];
    final major = dynamicModule is Map ? dynamicModule['major'] : null;
    if (major is! Map || major['type']?.toString() != 'MAJOR_TYPE_ARCHIVE') {
      continue;
    }
    final archive = major['archive'];
    if (archive is! Map) continue;
    final video = Map<String, dynamic>.from(archive);
    final bvid = video['bvid']?.toString() ?? '';
    final title = _cleanText(video['title']);
    if (!isBilibiliBvid(bvid) || title.isEmpty) continue;
    final author = modules['module_author'];
    items.add(
      BilibiliSearchItem(
        bvid: bvid,
        title: title,
        author: author is Map ? _cleanText(author['name']) : '',
        cover: bilibiliHttpsUrl(video['cover']),
        durationMs: bilibiliDurationMs(video['duration_text']),
      ),
    );
  }
  final hasMore = data['has_more'] == true;
  final offset = data['offset']?.toString() ?? '';
  final next =
      hasMore && offset.isNotEmpty && offset != cursor && items.isNotEmpty
      ? offset
      : null;
  return BilibiliTrackPage(items: items, nextCursor: next);
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
