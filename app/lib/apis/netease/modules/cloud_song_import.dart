// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 云盘导入：把已匹配的歌曲落库到我的云盘（对齐 cloud_song_import.ts）
library;

import 'dart:convert';

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmCloudSongImport = (query, request) {
  final data = <String, dynamic>{
    'uploadType': 0,
    'songs': jsonEncode([
      {
        'songId': query['songId'],
        'bitrate': 999000,
        'song': query['song'],
        'artist': query['artist'] ?? '未知艺术家',
        'album': query['album'] ?? '未知专辑',
        'fileName': '${query['song']}.${query['fileType']}',
      },
    ]),
  };
  return request('/api/cloud/user/song/import', data, nmCreateOption(query));
};
