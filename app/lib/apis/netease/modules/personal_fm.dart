// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 私人 FM（需登录，对齐 personal_fm.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmPersonalFm = (query, request) =>
    request('/api/v1/radio/get', <String, dynamic>{}, nmCreateOption(query, 'weapi'));
