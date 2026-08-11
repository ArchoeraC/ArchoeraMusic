/// 多类型搜索（一次返回歌曲/歌手/歌单的前几条命中，对齐 search_multimatch.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmSearchMultimatch = (query, request) {
  final data = <String, dynamic>{
    'type': query['type'] ?? 1,
    's': query['keywords'] ?? '',
  };
  return request('/api/search/suggest/multimatch', data, nmCreateOption(query, 'weapi'));
};
