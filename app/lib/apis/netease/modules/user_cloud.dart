// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 用户云盘歌曲列表（对齐 user_cloud.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmUserCloud = (query, request) {
  final data = <String, dynamic>{
    'limit': query['limit'] ?? 30,
    'offset': query['offset'] ?? 0,
  };
  return request('/api/v1/cloud/get', data, nmCreateOption(query, 'weapi'));
};
