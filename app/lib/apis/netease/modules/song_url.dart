/// 获取歌曲播放地址（v1 端点，level 而非裸 br，对齐 song_url.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmSongUrl = (query, request) {
  final ids = query['id'] ?? query['ids'];
  final data = <String, dynamic>{
    'ids': '[${'$ids'.split(',').join(',')}]',
    'level': query['level'] ?? 'exhigh',
    'encodeType': 'flac',
  };
  return request('/api/song/enhance/player/url/v1', data, nmCreateOption(query));
};
