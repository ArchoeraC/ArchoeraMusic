/// 用户收藏的专辑列表（对齐 album_sublist.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmAlbumSublist = (query, request) {
  final data = <String, dynamic>{
    'limit': query['limit'] ?? 50,
    'offset': query['offset'] ?? 0,
    'total': true,
  };
  return request('/api/album/sublist', data, nmCreateOption(query, 'weapi'));
};
