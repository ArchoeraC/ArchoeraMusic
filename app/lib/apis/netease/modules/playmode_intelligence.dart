/// 心动模式 / 智能播放列表（对齐 playmode_intelligence.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmPlaymodeIntelligence = (query, request) {
  final data = <String, dynamic>{
    'songId': query['id'],
    'type': 'fromPlayOne',
    'playlistId': query['pid'],
    'startMusicId': query['sid'] ?? query['id'],
    'count': query['count'] ?? 1,
  };
  return request('/api/playmode/intelligence/list', data, nmCreateOption(query, 'weapi'));
};
