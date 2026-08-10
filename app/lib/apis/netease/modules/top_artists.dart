/// 热门歌手（无需登录，对齐 top_artists.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmTopArtists = (query, request) {
  final data = <String, dynamic>{
    'offset': 0,
    'total': true,
    'limit': query['limit'] ?? 50,
  };
  return request('/api/artist/top', data, nmCreateOption(query, 'weapi'));
};
