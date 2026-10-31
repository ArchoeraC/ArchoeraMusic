// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Bilibili 视频详情 / 分P（`/x/web-interface/view`）。
library;

import '../core/request.dart';
import '../core/types.dart';

Future<BilibiliVideoDetail> bilibiliVideoDetail(
  BilibiliRequest request,
  String bvid,
) async {
  if (!isBilibiliBvid(bvid)) {
    throw const BilibiliApiException(
      'Invalid Bilibili video id.',
      kind: BilibiliErrorKind.invalidRequest,
    );
  }
  final root = await request.getJson(
    '/x/web-interface/view',
    params: {'bvid': bvid},
  );
  final data = bilibiliData(root);
  final actualBvid = data['bvid']?.toString() ?? bvid;
  if (!isBilibiliBvid(actualBvid)) {
    throw const BilibiliApiException(
      'Bilibili returned an invalid video id.',
      kind: BilibiliErrorKind.invalidResponse,
    );
  }
  final title = _cleanText(data['title']);
  if (title.isEmpty) {
    throw const BilibiliApiException(
      'Bilibili video has no title.',
      kind: BilibiliErrorKind.invalidResponse,
    );
  }
  final owner = data['owner'];
  final author = owner is Map ? _cleanText(owner['name']) : '';
  final rawPages = data['pages'];
  final rows = rawPages is List ? rawPages : const [];
  final parts = <BilibiliPart>[];
  for (final entry in rows) {
    if (entry is! Map) continue;
    final page = Map<String, dynamic>.from(entry);
    final cid = _asInt(page['cid']);
    if (cid == null || cid <= 0) continue;
    final pageNo = _asInt(page['page']) ?? parts.length + 1;
    final partTitle = _cleanText(page['part']);
    parts.add(
      BilibiliPart(
        cid: cid,
        page: pageNo,
        title: partTitle.isEmpty ? 'P$pageNo' : partTitle,
        durationMs: bilibiliDurationMs(page['duration']),
      ),
    );
  }
  // 少数接口不返回 pages：用顶层 cid 构造唯一分段。
  if (parts.isEmpty) {
    final cid = _asInt(data['cid']);
    if (cid != null && cid > 0) {
      parts.add(
        BilibiliPart(
          cid: cid,
          page: 1,
          title: title,
          durationMs: bilibiliDurationMs(data['duration']),
        ),
      );
    }
  }
  if (parts.isEmpty) {
    throw const BilibiliApiException(
      'This Bilibili video has no playable parts.',
      kind: BilibiliErrorKind.unavailable,
    );
  }

  return BilibiliVideoDetail(
    aid: _asInt(data['aid']) ?? 0,
    bvid: actualBvid,
    title: title,
    owner: author,
    cover: bilibiliHttpsUrl(data['pic']),
    durationMs: bilibiliDurationMs(data['duration']),
    parts: parts,
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
