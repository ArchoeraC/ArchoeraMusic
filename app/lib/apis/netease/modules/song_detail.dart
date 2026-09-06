// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 获取歌曲详情（对齐 song_detail.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmSongDetail = (query, request) {
  final ids = (query['ids'] as String? ?? '')
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  final data = <String, dynamic>{
    'c': '[${ids.map((id) => '{"id":$id}').join(',')}]',
  };
  return request('/api/v3/song/detail', data, nmCreateOption(query));
};
