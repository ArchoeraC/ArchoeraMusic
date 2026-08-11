/// 歌词（旧版，对齐 lyric.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmLyric = (query, request) {
  final data = <String, dynamic>{
    'id': query['id'],
    'tv': -1,
    'lv': -1,
    'rv': -1,
    'kv': -1,
    '_nmclfl': 1,
  };
  return request('/api/song/lyric', data, nmCreateOption(query));
};
