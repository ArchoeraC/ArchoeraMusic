/// 红心 / 取消红心（对齐 like.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmLike = (query, request) {
  final data = <String, dynamic>{
    'trackId': query['id'],
    'like': query['like'] == true || query['like'] == 'true',
    'time': 3,
  };
  return request('/api/song/like', data, nmCreateOption(query, 'weapi'));
};
