// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 汽水歌单详情（PC `/luna/pc/playlist/detail`，免登录游标分页）。
///
/// 响应：`playlist`（歌单元数据）+ `media_resources[].entity.track_wrapper.track`
/// + `next_cursor` / `has_more`。
library;

import '../core/config.dart';
import '../core/request.dart';
import '../core/types.dart';
import 'mappers.dart';

SodaModule sodaPlaylist = (params) async {
  final id = '${params['id'] ?? ''}';
  if (id.isEmpty) return {'code': 400, 'message': 'id required'};
  final cursor = '${params['cursor'] ?? ''}';
  final limit = (params['limit'] as num?)?.toInt() ?? 100;

  final uri = Uri.parse('$sodaApiBase/luna/pc/playlist/detail').replace(
    queryParameters: <String, String>{
      ...sodaPcAppParams(),
      'playlist_id': id,
      'cursor': cursor,
      'count': '$limit',
    },
  );
  final resp = await sodaGetJson(uri, headers: const {
    'User-Agent': sodaPcAppUa,
  });

  final resources = resp['media_resources'];
  final songs = <Map<String, dynamic>>[];
  if (resources is List) {
    for (final r in resources.whereType<Map>()) {
      final entity = r['entity'];
      final wrapper = (entity is Map && entity['track_wrapper'] is Map)
          ? entity['track_wrapper'] as Map
          : null;
      final track = (wrapper != null && wrapper['track'] is Map)
          ? wrapper['track'] as Map
          : null;
      if (track != null) songs.add(sodaMapTrack(track));
    }
  }

  final pl = resp['playlist'] is Map
      ? resp['playlist'] as Map
      : const <dynamic, dynamic>{};
  return {
    'code': 200,
    'playlist': sodaMapPlaylist(pl),
    'songs': songs,
    'nextCursor': '${resp['next_cursor'] ?? ''}',
    'hasMore': resp['has_more'] == true,
  };
};
