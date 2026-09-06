// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 默认搜索关键词（搜索框 placeholder，对齐 search_default.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmSearchDefault = (query, request) =>
    request('/api/search/defaultkeyword/get', {}, nmCreateOption(query));
