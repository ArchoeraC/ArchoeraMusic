// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 本地歌曲匹配（根据 title/album/artist/duration 猜云端对应歌曲，对齐 search_match.ts）
library;

import 'dart:convert';

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmSearchMatch = (query, request) {
  final songs = [
    {
      'title': query['title'] ?? '',
      'album': query['album'] ?? '',
      'artist': query['artist'] ?? '',
      'duration': query['duration'] ?? 0,
      'persistId': query['md5'],
    },
  ];
  final data = <String, dynamic>{'songs': jsonEncode(songs)};
  return request('/api/search/match/new', data, nmCreateOption(query));
};
