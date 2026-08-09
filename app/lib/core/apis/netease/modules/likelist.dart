/// 喜欢歌曲 id 列表（对齐 likelist.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmLikelist = (query, request) {
  final data = <String, dynamic>{'uid': query['uid']};
  return request('/api/song/like/get', data, nmCreateOption(query, 'weapi'));
};
