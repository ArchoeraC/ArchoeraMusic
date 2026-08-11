/// 新碟上架（无需登录，对齐 album_new.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmAlbumNew = (query, request) {
  final data = <String, dynamic>{
    'area': 'ALL',
    'offset': 0,
    'total': true,
    'limit': query['limit'] ?? 30,
  };
  return request('/api/album/new', data, nmCreateOption(query, 'weapi'));
};
