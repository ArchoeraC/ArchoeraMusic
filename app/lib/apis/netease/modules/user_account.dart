// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 当前登录账号信息（对齐 user_account.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmUserAccount = (query, request) =>
    request('/api/nuser/account/get', {}, nmCreateOption(query, 'weapi'));
