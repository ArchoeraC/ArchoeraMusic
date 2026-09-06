// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 私人 FM 减少推荐（不喜欢，对齐 fm_trash.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmFmTrash = (query, request) {
  final data = <String, dynamic>{
    'songId': query['id'],
    'alg': query['alg'] ?? 'RT',
    'time': query['time'] ?? 25,
  };
  return request('/api/radio/trash/add', data, nmCreateOption(query, 'weapi'));
};
