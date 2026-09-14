// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 汽水搜索（Android `/luna/search/{track|album|playlist}`，免登录、免签名）。
///
/// 对齐 `music-lib/soda` `sodaAndroidSearchURL`；出站为官方 `api.qishui.com`。
/// 响应：`result_groups[].data[].entity.{track|album|playlist}`。
library;

import '../core/config.dart';
import '../core/request.dart';
import '../core/types.dart';
import 'mappers.dart';

/// 搜索类型码（对齐主项目四分类习惯）：0 单曲 / 1 专辑 / 2 歌单。
const int sodaSearchTypeTrack = 0;
const int sodaSearchTypeAlbum = 1;
const int sodaSearchTypePlaylist = 2;

String _kindOf(int type) => switch (type) {
  1 => 'album',
  2 => 'playlist',
  _ => 'track',
};

/// 取 `result_groups[].data[].entity.<key>` 的实体列表。
List<Map<String, dynamic>> _entities(Map<String, dynamic> resp, String key) {
  final groups = resp['result_groups'];
  if (groups is! List) return const [];
  final out = <Map<String, dynamic>>[];
  for (final g in groups.whereType<Map>()) {
    final data = g['data'];
    if (data is! List) continue;
    for (final d in data.whereType<Map>()) {
      final entity = d['entity'];
      if (entity is Map && entity[key] is Map) {
        out.add(Map<String, dynamic>.from(entity[key] as Map));
      }
    }
  }
  return out;
}

Future<Map<String, dynamic>> _androidSearch(
  String kind,
  String keyword,
  int page,
  int limit,
) {
  final cursor = (page - 1) * limit;
  final uri = Uri.parse('$sodaApiBase/luna/search/$kind').replace(
    queryParameters: <String, String>{
      ...sodaAndroidSearchParams(),
      'q': keyword,
      'cursor': '$cursor',
      'count': '$limit',
    },
  );
  return sodaGetJson(uri, headers: const {
    'User-Agent': sodaAndroidUa,
    'content-type': 'application/json; charset=UTF-8',
  });
}

/// 搜索模块：`type` 0 单曲 / 1 专辑 / 2 歌单。
SodaModule sodaSearch = (params) async {
  final keywords = params['keywords'] as String?;
  final page = (params['page'] as num?)?.toInt() ?? 1;
  final limit = (params['limit'] as num?)?.toInt() ?? 20;
  final type = (params['type'] as num?)?.toInt() ?? sodaSearchTypeTrack;

  if (keywords == null || keywords.isEmpty) {
    return {'code': 400, 'total': 0, 'message': 'keywords required'};
  }

  final resp = await _androidSearch(_kindOf(type), keywords, page, limit);
  final total = (page - 1) * limit;

  switch (type) {
    case sodaSearchTypeAlbum:
      final albums = _entities(resp, 'album').map(sodaMapAlbum).toList();
      return {
        'code': 200,
        'total': total + albums.length,
        'albums': albums,
        'hasMore': albums.length >= limit,
      };
    case sodaSearchTypePlaylist:
      final playlists = _entities(resp, 'playlist').map(sodaMapPlaylist).toList();
      return {
        'code': 200,
        'total': total + playlists.length,
        'playlists': playlists,
        'hasMore': playlists.length >= limit,
      };
    default:
      final songs = _entities(resp, 'track').map(sodaMapTrack).toList();
      return {
        'code': 200,
        'total': total + songs.length,
        'songs': songs,
        'hasMore': songs.length >= limit,
      };
  }
};
