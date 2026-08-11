/// 搜索（普通，对齐 search.ts）
/// type: 1 单曲 / 10 专辑 / 100 歌手 / 1000 歌单 / 1002 用户 / 1004 MV / 1006 歌词 / 1009 电台 / 1014 视频
/// 特例：type=2000 走语音搜索接口
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmSearch = (query, request) {
  if (query['type'] != null && '${query['type']}' == '2000') {
    final voice = <String, dynamic>{
      'keyword': query['keywords'],
      'scene': 'normal',
      'limit': query['limit'] ?? 30,
      'offset': query['offset'] ?? 0,
    };
    return request('/api/search/voice/get', voice, nmCreateOption(query));
  }
  final data = <String, dynamic>{
    's': query['keywords'],
    'type': query['type'] ?? 1,
    'limit': query['limit'] ?? 30,
    'offset': query['offset'] ?? 0,
  };
  return request('/api/search/get', data, nmCreateOption(query));
};
