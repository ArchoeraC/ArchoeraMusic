// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 退出登录（对齐 logout.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmLogout = (query, request) =>
    request('/api/logout', {}, nmCreateOption(query));
