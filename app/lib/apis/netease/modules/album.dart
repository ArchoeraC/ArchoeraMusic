// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 专辑详情（元数据 + 曲目，对齐 album.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmAlbum = (query, request) =>
    request('/api/v1/album/${query['id']}', <String, dynamic>{}, nmCreateOption(query, 'weapi'));
