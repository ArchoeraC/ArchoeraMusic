// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Bilibili 视频评论（只读，`/x/v2/reply/wbi/main`）。
///
/// 公开可读，无需登录；WBI 签名 + 游标分页（`cursor.next`）。
/// `mode=3` 热门 / `mode=2` 最新。评论区关闭时返回空页。
library;

import '../core/request.dart';
import '../core/types.dart';

Future<BilibiliCommentPage> bilibiliVideoComments(
  BilibiliRequest request, {
  required String aid,
  required bool hot,
  int next = 0,
}) async {
  final oid = int.tryParse(aid);
  if (oid == null || oid <= 0 || next < 0) {
    throw const BilibiliApiException(
      'Invalid Bilibili comment target.',
      kind: BilibiliErrorKind.invalidRequest,
    );
  }
  final root = await request.getJson(
    '/x/v2/reply/wbi/main',
    signed: true,
    params: {
      'type': '1',
      'oid': '$oid',
      'mode': hot ? '3' : '2',
      'next': '$next',
      'ps': '20',
      'plat': '1',
    },
  );
  final data = bilibiliData(root);

  final items = <BilibiliComment>[];
  final seen = <String>{};
  void appendRows(Object? raw) {
    if (raw is! List) return;
    for (final entry in raw) {
      if (entry is! Map) continue;
      final comment = _parseComment(Map<String, dynamic>.from(entry));
      if (comment == null) continue;
      if (seen.add(comment.id)) items.add(comment);
    }
  }

  // 置顶评论只在第一页返回，先展示。
  appendRows(data['top_replies']);
  appendRows(data['replies']);

  final cursor = data['cursor'];
  final total =
      _asInt(cursor is Map ? cursor['all_count'] : null) ?? items.length;
  int? nextCursor;
  if (cursor is Map && cursor['is_end'] != true) {
    final value = _asInt(cursor['next']);
    if (value != null && value > 0 && value != next) nextCursor = value;
  }
  return BilibiliCommentPage(
    list: items,
    total: total < items.length ? items.length : total,
    next: nextCursor,
  );
}

BilibiliComment? _parseComment(Map<String, dynamic> row) {
  final id = row['rpid']?.toString() ?? row['rpid_str']?.toString() ?? '';
  if (id.isEmpty) return null;

  final member = row['member'];
  final userName = member is Map ? _cleanText(member['uname']) : '';
  if (userName.isEmpty) return null;

  final content = row['content'];
  final text = content is Map ? _cleanText(content['message']) : '';
  if (text.isEmpty) return null;

  final control = row['reply_control'];
  final rawLocation = control is Map ? _cleanText(control['location']) : '';
  final location = rawLocation.replaceFirst(RegExp(r'^IP属地[：:]\s*'), '');
  final ctime = _asInt(row['ctime']);

  final replies = <BilibiliComment>[];
  final rawReplies = row['replies'];
  if (rawReplies is List) {
    for (final entry in rawReplies) {
      if (entry is! Map) continue;
      final reply = _parseComment(Map<String, dynamic>.from(entry));
      if (reply != null) replies.add(reply);
    }
  }

  return BilibiliComment(
    id: id,
    userName: userName,
    avatar: member is Map ? bilibiliHttpsUrl(member['avatar']) : null,
    text: text,
    location: location.isEmpty ? null : location,
    timeMs: ctime == null || ctime <= 0 ? null : ctime * 1000,
    likedCount: _asInt(row['like']) ?? 0,
    replyTotal: _asInt(row['rcount']) ?? replies.length,
    replies: replies,
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
