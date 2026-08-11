/// 每日推荐歌曲（每日 30 首，需登录，对齐 recommend_songs.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmRecommendSongs = (query, request) {
  final cookie = query['cookie'];
  if (cookie is Map) {
    cookie['os'] = 'ios';
  }
  return request('/api/v3/discovery/recommend/songs', <String, dynamic>{}, nmCreateOption(query, 'weapi'));
};
