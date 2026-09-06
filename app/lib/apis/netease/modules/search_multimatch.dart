// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 多类型搜索（一次返回歌曲/歌手/歌单的前几条命中，对齐 search_multimatch.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmSearchMultimatch = (query, request) {
  final data = <String, dynamic>{
    'type': query['type'] ?? 1,
    's': query['keywords'] ?? '',
  };
  return request('/api/search/suggest/multimatch', data, nmCreateOption(query, 'weapi'));
};
