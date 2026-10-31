// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// B 站只读资料库：收藏夹 / 收藏夹内容 / 观看历史。
///
/// 所有接口均需登录态；不在本地伪造数据，也不写云端。
library;

import 'dart:convert';

import '../core/request.dart';
import '../core/types.dart';

Future<List<BilibiliFavFolder>> bilibiliFavFolders(
  BilibiliRequest request,
  String mid,
) async {
  if (mid.isEmpty) {
    throw const BilibiliApiException(
      'Bilibili sign-in is required.',
      kind: BilibiliErrorKind.authRequired,
    );
  }
  final root = await request.getJson(
    '/x/v3/fav/folder/created/list-all',
    params: {'up_mid': mid},
  );
  final data = bilibiliData(root);
  final raw = data['list'];
  if (raw is! List) {
    if ((_asInt(data['count']) ?? 0) == 0) return const [];
    throw const BilibiliApiException(
      'Bilibili favorites response is incomplete.',
      kind: BilibiliErrorKind.invalidResponse,
    );
  }
  final folders = <BilibiliFavFolder>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final row = Map<String, dynamic>.from(entry);
    final id = _asInt(row['id']);
    final title = _cleanText(row['title']);
    if (id == null || id <= 0 || title.isEmpty) continue;
    folders.add(
      BilibiliFavFolder(
        id: '$id',
        title: title,
        cover: bilibiliHttpsUrl(row['cover']),
        count: _asInt(row['media_count']) ?? 0,
      ),
    );
  }
  return folders;
}

Future<BilibiliTrackPage<BilibiliSearchItem>> bilibiliFavFolderTracks(
  BilibiliRequest request,
  String folderId, {
  int page = 1,
}) async {
  final id = int.tryParse(folderId);
  if (id == null || id <= 0) {
    throw const BilibiliApiException(
      'Invalid Bilibili favorites folder.',
      kind: BilibiliErrorKind.invalidRequest,
    );
  }
  final pn = page < 1 ? 1 : page;
  final root = await request.getJson(
    '/x/v3/fav/resource/list',
    params: {
      'media_id': '$id',
      'pn': '$pn',
      'ps': '20',
      'order': 'mtime',
      'type': '0',
    },
  );
  final data = bilibiliData(root);
  final raw = data['medias'];
  if (raw is! List) {
    final info = data['info'];
    final count = info is Map ? _asInt(info['media_count']) : null;
    if ((count ?? 0) == 0) return const BilibiliTrackPage(items: []);
    throw const BilibiliApiException(
      'Bilibili favorites response is incomplete.',
      kind: BilibiliErrorKind.invalidResponse,
    );
  }
  final items = <BilibiliSearchItem>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final row = Map<String, dynamic>.from(entry);
    final type = _asInt(row['type']);
    if (type != null && type != 2) continue;
    final bvid = row['bvid']?.toString() ?? '';
    if (!isBilibiliBvid(bvid)) continue;
    final title = _cleanText(row['title']);
    if (title.isEmpty) continue;
    final upper = row['upper'];
    final author = upper is Map ? _cleanText(upper['name']) : '';
    items.add(
      BilibiliSearchItem(
        bvid: bvid,
        title: title,
        author: author,
        cover: bilibiliHttpsUrl(row['cover']),
        durationMs: bilibiliDurationMs(row['duration']),
      ),
    );
  }
  final hasMore = data['has_more'] == true && items.isNotEmpty;
  return BilibiliTrackPage(
    items: items,
    nextCursor: hasMore ? '${pn + 1}' : null,
  );
}

Future<BilibiliTrackPage<BilibiliSearchItem>> bilibiliHistory(
  BilibiliRequest request, {
  String? cursor,
}) async {
  final params = <String, String>{'ps': '20', 'type': 'archive'};
  if (cursor != null && cursor.isNotEmpty) {
    final decoded = _decodeHistoryCursor(cursor);
    if (decoded == null) {
      throw const BilibiliApiException(
        'Invalid Bilibili history cursor.',
        kind: BilibiliErrorKind.invalidRequest,
      );
    }
    params
      ..['business'] = decoded.business
      ..['max'] = '${decoded.max}'
      ..['view_at'] = '${decoded.viewAt}';
  }

  final root = await request.getJson(
    '/x/web-interface/history/cursor',
    params: params,
  );
  final data = bilibiliData(root);
  final raw = data['list'];
  if (raw is! List) {
    throw const BilibiliApiException(
      'Bilibili history response is incomplete.',
      kind: BilibiliErrorKind.invalidResponse,
    );
  }
  final items = <BilibiliSearchItem>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final row = Map<String, dynamic>.from(entry);
    final history = row['history'];
    if (history is! Map) continue;
    final h = Map<String, dynamic>.from(history);
    if (h['business']?.toString() != 'archive') continue;
    final bvid = h['bvid']?.toString() ?? '';
    if (!isBilibiliBvid(bvid)) continue;
    final title = _cleanText(row['title']);
    if (title.isEmpty) continue;
    final cid = _asInt(h['cid']);
    items.add(
      BilibiliSearchItem(
        bvid: bvid,
        title: title,
        author: _cleanText(row['author_name']),
        cover: bilibiliHttpsUrl(row['cover']),
        durationMs: bilibiliDurationMs(row['duration']),
        cid: cid != null && cid > 0 ? '$cid' : null,
      ),
    );
  }

  final next = _encodeHistoryCursor(data['cursor']);
  return BilibiliTrackPage(
    items: items,
    nextCursor: next != null && next != cursor && items.isNotEmpty
        ? next
        : null,
  );
}

class _HistoryCursor {
  const _HistoryCursor({
    required this.max,
    required this.viewAt,
    required this.business,
  });

  final int max;
  final int viewAt;
  final String business;
}

_HistoryCursor? _decodeHistoryCursor(String raw) {
  try {
    final normalized = base64Url.normalize(raw);
    final decoded = jsonDecode(utf8.decode(base64Url.decode(normalized)));
    if (decoded is! Map) return null;
    final max = _asInt(decoded['max']);
    final viewAt = _asInt(decoded['view_at']);
    final business = decoded['business']?.toString() ?? '';
    if (max == null || max <= 0 || viewAt == null || viewAt <= 0) {
      return null;
    }
    if (business.isEmpty || business.length > 32) return null;
    return _HistoryCursor(max: max, viewAt: viewAt, business: business);
  } catch (_) {
    return null;
  }
}

String? _encodeHistoryCursor(Object? raw) {
  if (raw is! Map) return null;
  final max = _asInt(raw['max']);
  final viewAt = _asInt(raw['view_at']);
  final business = raw['business']?.toString() ?? '';
  if (max == null || max <= 0 || viewAt == null || viewAt <= 0) return null;
  if (business.isEmpty || business.length > 32) return null;
  final encoded = jsonEncode({
    'max': max,
    'view_at': viewAt,
    'business': business,
  });
  return base64Url.encode(utf8.encode(encoded)).replaceAll('=', '');
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
