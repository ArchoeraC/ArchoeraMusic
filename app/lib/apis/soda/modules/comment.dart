// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 汽水歌曲评论（PC `/luna/pc/comments`）。
///
/// 读取免登录（`group_type` 0 最新 / 1 热门，`cursor` 为偏移量）；发布
/// `/luna/pc/comments/create` 需登录 cookie（经 [sodaCookieHeader] 注入）。
library;

import 'dart:convert';

import '../core/config.dart';
import '../core/request.dart';
import '../core/types.dart';
import 'mappers.dart';

/// 默认每页评论数。
const int _sodaCommentPageSize = 20;

/// 读取评论：`id`(track id)、`cursor`(偏移)、`limit`、`groupType`(0/1)。
SodaModule sodaComments = (params) async {
  final id = '${params['id'] ?? ''}'.trim();
  if (id.isEmpty) {
    return {'code': 400, 'comments': const [], 'message': 'id required'};
  }
  final cursor = (params['cursor'] as num?)?.toInt() ?? 0;
  final limit = (params['limit'] as num?)?.toInt() ?? _sodaCommentPageSize;
  final groupType = (params['groupType'] as num?)?.toInt() ?? 0;

  final uri = Uri.parse('$sodaApiBase/luna/pc/comments').replace(
    queryParameters: <String, String>{
      ...sodaPcAppParams(),
      'group_id': id,
      'cursor': '$cursor',
      'count': '$limit',
      'group_type': '$groupType',
      'image_strategy': '2',
    },
  );
  final resp = await sodaGetJson(uri, headers: const {
    'User-Agent': sodaPcAppUa,
    'content-type': 'application/json; charset=UTF-8',
  });
  final code = sodaInt(resp['status_code']);
  if (code != 0) {
    return {
      'code': code,
      'comments': const [],
      'message': _statusMessage(resp, 'comments failed'),
    };
  }
  final raw = resp['comments'] is List ? resp['comments'] as List : const [];
  final comments = raw.whereType<Map>().map(_mapComment).toList();
  return {
    'code': 200,
    'comments': comments,
    'total': sodaInt(resp['count']),
    'cursor': cursor + comments.length,
    'hasMore': resp['has_more'] == true,
  };
};

/// 发布评论（需登录）：`id`、`text`。
SodaModule sodaSendComment = (params) async {
  final id = '${params['id'] ?? ''}'.trim();
  final text = '${params['text'] ?? ''}'.trim();
  if (id.isEmpty || text.isEmpty) {
    return {'code': 400, 'message': 'id/text required'};
  }
  final uri = Uri.parse('$sodaApiBase/luna/pc/comments/create').replace(
    queryParameters: sodaPcAppParams(),
  );
  final res = await sodaRawRequest(
    'POST',
    uri,
    body: jsonEncode({'group_id': id, 'text': text, 'group_type': 0}),
    headers: const {
      'User-Agent': sodaPcAppUa,
      'content-type': 'application/json; charset=UTF-8',
      'Referer': 'https://www.qishui.com/',
    },
    cookieHeader: sodaCookieHeader(),
  );
  final code = sodaInt(res.json['status_code']);
  if (code != 0) {
    return {'code': code, 'message': _statusMessage(res.json, 'send failed')};
  }
  return {'code': 200, 'ok': true};
};

String _statusMessage(Map<String, dynamic> resp, String fallback) {
  final info = resp['status_info'];
  final msg = info is Map ? '${info['status_msg'] ?? ''}' : '';
  return msg.isEmpty ? fallback : msg;
}

Map<String, dynamic> _mapComment(Map c) {
  final user = c['user'] is Map ? c['user'] as Map : const {};
  return <String, dynamic>{
    'id': '${c['id'] ?? ''}',
    'content': '${c['content'] ?? ''}',
    'nickname': '${user['nickname'] ?? user['public_name'] ?? ''}',
    'avatar': sodaImageUrl(
      user['medium_avatar_url'] ?? user['thumb_avatar_url'],
    ),
    'like': sodaInt(c['count_digged']),
    'time': sodaInt(c['time_created']) * 1000,
    'ipLabel': '${c['ip_label'] ?? ''}',
  };
}
