/// 歌词（新版，含逐字歌词 yrc，对齐 lyric_new.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmLyricNew = (query, request) {
  final data = <String, dynamic>{
    'id': query['id'],
    'cp': false,
    'tv': 0,
    'lv': 0,
    'rv': 0,
    'kv': 0,
    'yv': 0,
    'ytv': 0,
    'yrv': 0,
  };
  return request('/api/song/lyric/v1', data, nmCreateOption(query));
};
