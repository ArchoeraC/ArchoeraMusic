/// 获取歌曲下载地址（v1 端点，对齐 song_download_url.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmSongDownloadUrl = (query, request) {
  final data = <String, dynamic>{
    'id': query['id'],
    'level': query['level'] ?? 'exhigh',
  };
  return request('/api/song/enhance/download/url/v1', data, nmCreateOption(query));
};
