/// 用户收藏的歌手列表（对齐 artist_sublist.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmArtistSublist = (query, request) {
  final data = <String, dynamic>{
    'limit': query['limit'] ?? 50,
    'offset': query['offset'] ?? 0,
    'total': true,
  };
  return request('/api/artist/sublist', data, nmCreateOption(query, 'weapi'));
};
