/// 用户歌单列表（对齐 user_playlist.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmUserPlaylist = (query, request) {
  final data = <String, dynamic>{
    'uid': query['uid'],
    'limit': query['limit'] ?? 30,
    'offset': query['offset'] ?? 0,
    'includeVideo': true,
  };
  return request('/api/user/playlist', data, nmCreateOption(query, 'weapi'));
};
