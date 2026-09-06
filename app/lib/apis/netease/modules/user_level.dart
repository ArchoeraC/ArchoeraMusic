// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 用户等级（听歌时长、登录天数等，对齐 user_level.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmUserLevel = (query, request) =>
    request('/api/user/level', {}, nmCreateOption(query, 'weapi'));
