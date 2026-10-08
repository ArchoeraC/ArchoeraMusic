// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 红心 / 取消红心（对齐 like.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmLike = (query, request) {
  final raw = query['like'];
  final isLike = raw != false && raw != 'false';
  final data = <String, dynamic>{
    'alg': 'itembased',
    'trackId': '${query['id']}',
    'like': isLike,
    'time': '3',
  };
  return request('/api/radio/like', data, nmCreateOption(query, 'weapi'));
};
