/// 推荐歌单（无需登录，对齐 personalized.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmPersonalized = (query, request) {
  final data = <String, dynamic>{
    'limit': query['limit'] ?? 30,
    'total': true,
    'n': 1000,
  };
  return request('/api/personalized/playlist', data, nmCreateOption(query, 'weapi'));
};
