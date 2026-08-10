/// 新建歌单（对齐 playlist_create.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmPlaylistCreate = (query, request) {
  final data = <String, dynamic>{
    'name': query['name'],
    'privacy': query['privacy'] ?? 0,
    'type': query['type'] ?? 'NORMAL',
  };
  return request('/api/playlist/create', data, nmCreateOption(query, 'weapi'));
};
