// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 汽水专辑详情（PC `/luna/pc/albums/{id}`，免登录）。
///
/// 响应：`album_info`（专辑元数据）+ `tracks[]`（曲目）。
library;

import '../core/config.dart';
import '../core/request.dart';
import '../core/types.dart';
import 'mappers.dart';

SodaModule sodaAlbum = (params) async {
  final id = '${params['id'] ?? ''}';
  if (id.isEmpty) return {'code': 400, 'message': 'id required'};

  final uri = Uri.parse('$sodaApiBase/luna/pc/albums/$id').replace(
    queryParameters: sodaPcAppParams(),
  );
  final resp = await sodaGetJson(uri, headers: const {
    'User-Agent': sodaPcAppUa,
  });

  final info = resp['album_info'] is Map
      ? resp['album_info'] as Map
      : const <dynamic, dynamic>{};
  final tracksRaw = resp['tracks'];
  final songs = <Map<String, dynamic>>[];
  if (tracksRaw is List) {
    for (final t in tracksRaw.whereType<Map>()) {
      songs.add(sodaMapTrack(t));
    }
  }

  return {
    'code': 200,
    'album': sodaMapAlbum(info),
    'songs': songs,
  };
};
