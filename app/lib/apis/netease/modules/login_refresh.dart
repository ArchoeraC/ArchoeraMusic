// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 登录态刷新（延长 MUSIC_U 有效期，对齐 login_refresh.ts）
library;

import '../core/option.dart';
import '../core/request.dart';
import '../core/types.dart';

NeteaseModule nmLoginRefresh = (query, request) async {
  final result = await request('/api/login/token/refresh', {}, nmCreateOption(query));
  final body = result.body;
  if (body['code'] == 200) {
    return NeteaseResponse(
      status: 200,
      body: {...body, 'cookie': result.cookie.join(';')},
      cookie: result.cookie,
    );
  }
  return result;
};
