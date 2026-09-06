// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 云盘歌词（对齐 cloud_lyric_get.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmCloudLyricGet = (query, request) {
  final data = <String, dynamic>{
    'userId': query['uid'],
    'songId': query['sid'],
    'lv': -1,
    'kv': -1,
  };
  return request('/api/cloud/lyric/get', data, nmCreateOption(query, 'eapi'));
};
