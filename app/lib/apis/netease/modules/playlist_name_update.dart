// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 更新歌单名（对齐 playlist_name_update.ts，走 eapi）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmPlaylistNameUpdate = (query, request) {
  final data = <String, dynamic>{'id': query['id'], 'name': query['name']};
  return request('/api/playlist/update/name', data, nmCreateOption(query, 'eapi'));
};
