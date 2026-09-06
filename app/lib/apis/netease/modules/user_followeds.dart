// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 粉丝列表（关注 TA 的人，对齐 user_followeds.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmUserFolloweds = (query, request) {
  final data = <String, dynamic>{
    'userId': query['uid'],
    'time': '0',
    'limit': query['limit'] ?? 20,
    'offset': query['offset'] ?? 0,
    'getcounts': 'true',
  };
  return request('/api/user/getfolloweds/${query['uid']}', data, nmCreateOption(query));
};
