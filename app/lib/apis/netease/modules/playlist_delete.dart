/// 删除歌单（对齐 playlist_delete.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmPlaylistDelete = (query, request) {
  final data = <String, dynamic>{'ids': '[${query['id']}]'};
  return request('/api/playlist/remove', data, nmCreateOption(query, 'weapi'));
};
