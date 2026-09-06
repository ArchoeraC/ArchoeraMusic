// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 搜索建议（web / mobile，对齐 search_suggest.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmSearchSuggest = (query, request) {
  final data = <String, dynamic>{'s': query['keywords'] ?? ''};
  final type = query['type'] == 'mobile' ? 'keyword' : 'web';
  return request('/api/search/suggest/$type', data, nmCreateOption(query, 'weapi'));
};
