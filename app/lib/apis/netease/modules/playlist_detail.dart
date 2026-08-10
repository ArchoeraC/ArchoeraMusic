/// 歌单详情（对齐 playlist_detail.ts，默认 eapi）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmPlaylistDetail = (query, request) {
  final data = <String, dynamic>{
    'id': query['id'],
    'n': 100000,
    's': query['s'] ?? 8,
  };
  return request('/api/v6/playlist/detail', data, nmCreateOption(query));
};
