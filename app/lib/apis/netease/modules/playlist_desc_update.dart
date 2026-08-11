/// 更新歌单描述（对齐 playlist_desc_update.ts，走 eapi）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmPlaylistDescUpdate = (query, request) {
  final data = <String, dynamic>{'id': query['id'], 'desc': query['desc'] ?? ''};
  return request('/api/playlist/desc/update', data, nmCreateOption(query, 'eapi'));
};
