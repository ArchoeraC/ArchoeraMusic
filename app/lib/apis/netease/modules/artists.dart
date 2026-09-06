// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 歌手信息与热门歌曲（对齐 artists.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmArtists = (query, request) =>
    request('/api/v1/artist/${query['id']}', <String, dynamic>{}, nmCreateOption(query, 'weapi'));
